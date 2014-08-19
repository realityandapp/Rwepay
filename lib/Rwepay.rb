require "Rwepay/version"
require "Rwepay/common"
require 'json'

module Rwepay

  class JSPayment
    attr_accessor :configs
    attr_accessor :package_options
    attr_accessor :brand_options

    def initialize(configs = {})
      @configs = Rwepay::Common.configs_check configs,
                                              [:app_id, :partner_id, :app_key, :partner_key]
    end

    def get_brand_request(options = {})
      brand_options = Rwepay::Common.configs_check options,
                                                   [:body, :notify_url, :out_trade_no, :total_fee, :spbill_create_ip]

      # create package
      brand_options[:key]       ||= @configs[:partner_key]
      brand_options[:partner]   ||= @configs[:partner_id]
      brand_options[:fee_type]  ||= '1'
      brand_options[:bank_type] ||= 'WX'
      brand_options[:input_charset] ||= 'GBK'

      final_params = Hash.new
      final_params[:appId]     = @configs[:app_id]
      final_params[:timeStamp] = Rwepay::Common.get_timestamps
      final_params[:nonceStr]  = Rwepay::Common.get_nonce_str
      final_params[:package]   = Rwepay::Common.get_package(brand_options)
      final_params[:signType]  = 'SHA1'
      final_params[:paySign]   = Rwepay::Common.pay_sign(
          :appid     => @configs[:app_id],
          :appkey    => @configs[:app_key],
          :noncestr  => final_params[:nonceStr],
          :package   => final_params[:package],
          :timestamp => final_params[:timeStamp],
      )
      final_params.to_json
    end

    def notify_verify?(params = {})
      params['key'] ||= @configs[:partner_key]
      Rwepay::Common.notify_sign(params) == params['sign'] and params['trade_state'] == '0'
    end

    def deliver_notify(options = {})
      options = Rwepay::Common.configs_check options,
                                             [:access_token, :open_id, :trans_id, :out_trade_no, :deliver_timestamp, :deliver_status, :deliver_msg]

      options[:app_id]  = @configs[:app_id]
      options[:app_key] = @configs[:app_key]

      Rwepay::Common.send_deliver_notify(options, options[:access_token])
    end

    def get_order_query(options = {})
      options = Rwepay::Common.configs_check options,
                                             [:access_token, :out_trade_no]

      options[:app_id]      = @configs[:app_id]
      options[:app_key]     = @configs[:app_key]
      options[:partner_key] = @configs[:partner_key]
      options[:partner_id]  = @configs[:partner_id]

      Rwepay::Common.get_order_query(options, options[:access_token])
    end

    # expire 7200 seconds, must be cached!
    def get_access_token(app_secret)
      begin
        response = Faraday.get("https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=#{@configs[:app_id]}&secret=#{app_secret}")
        response = JSON.parse response.body
        if response['access_token'] != nil
          response['access_token']
        else
          false
        end
      rescue
        false
      end
    end

    def update_feedback(options = {})
      options = Rwepay::Common.configs_check options,
                                             [:access_token, :open_id, :feedback_id]
      begin
        response = Faraday.get("https://api.weixin.qq.com/payfeedback/update?access_token=#{options[:access_token]}&openid=#{options[:open_id]}&feedbackid=#{options[:feedback_id]}")
        response = JSON.parse response.body
        if response['errcode'] == 0
          true
        else
          false
        end
      rescue
        false
      end
    end
    
    # 申请退款
    # 用以下命令生成相应的cert和cert_key, 其中xxxxx.pfx在财付通申请成功后发来的邮件中
    # cert: openssl pkcs12 -in xxxxxx.pfx -nokeys -out tenpay.crt
    # cert_key: openssl pkcs12 -in xxxxxx.pfx -out tenpay.pem -nodes 
    def request_refund(options = {})
      options = Rwepay::Common.configs_check options, [:transaction_id, :out_refund_no, :total_fee, :refund_fee, :op_user_passwd, :cert_key_path, :cert_path]

      init_options = Hash.new 

      # 填写为 1.1 时,操作员密码为 MD5(密码)值 
      init_options[:service_version] = "1.1"
      init_options[:partner] ||= @configs[:partner_id] 
      init_options[:out_refund_no] = options[:out_refund_no]
      init_options[:total_fee] = options[:total_fee]
      init_options[:refund_fee] = options[:refund_fee]
      init_options[:transaction_id] = options[:transaction_id]
      init_options[:op_user_passwd] = options[:op_user_passwd]
      init_options[:op_user_id] ||= @configs[:partner_id] 
      init_options[:key] ||= @configs[:partner_key]

      params = Rwepay::Common.get_request_params(init_options, true, true)

      cert = OpenSSL::X509::Certificate.new File.read(options[:cert_path])
      cert_key = OpenSSL::PKey::RSA.new( File.read(options[:cert_key_path]), @configs[:partner_id])
      query_url =   "https://mch.tenpay.com/refundapi/gateway/refund.xml?#{params}"
      begin
        conn = Faraday.new(url: query_url, ssl: {client_cert: cert, client_key: cert_key})
        response = conn.get

        # GBK encoding originally
        response = response.body.encode("utf-8", "GB18030")
        result = Hash.from_xml(response)['root']
        if result['retcode'] == "0"
          return true, result
        else
          return false, result 
        end
      rescue => err
        return false, err
      end
    end

    # 退款状态查询
    def refund_query(options = {})
      options = Rwepay::Common.configs_check options, [:transaction_id, :out_refund_no, :refund_id]
      init_options = Hash.new

      init_options[:out_refund_no] = options[:out_refund_no]
      init_options[:partner] ||= @configs[:partner_id]
      init_options[:refund_id] = options[:refund_id]
      init_options[:transaction_id] = options[:transaction_id]
      init_options[:key] ||= @configs[:partner_key]

      params = Rwepay::Common.get_request_params(init_options, true, true)
      begin
        conn = Faraday.new(url:  "https://gw.tenpay.com/gateway/normalrefundquery.xml?#{params}")
        response = conn.get
        response = Hash.from_xml(response.body.encode("utf-8", "GB18030"))['root']
        if response['retcode'] == "0"
          return true, response
        else
          return false, response
        end
      rescue => err
        return false, err
      end
    end

    # 对账单下载
    # trans_time: "2014-08-12"
    def download_statement(options = {})
      options = Rwepay::Common.configs_check options, [:trans_time]

      init_options = Hash.new

      init_options[:spid] = @configs[:partner_id] 
      init_options[:trans_time] = options[:trans_time] 
      init_options[:stamp] = Time.now.to_i
      init_options[:key] = @configs[:partner_key]
      
      params = Rwepay::Common.get_request_params(init_options)
      begin
        conn = Faraday.new(url:  "http://mch.tenpay.com/cgi-bin/mchdown_real_new.cgi?#{params}")
        response = conn.get 
        response = response.body.encode("utf-8", "GB18030")
      rescue => err
        return false, err
      end

    end
  end

  # @TODO
  class NativePayment

  end
  
end
