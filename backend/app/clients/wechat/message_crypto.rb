module Wechat
  class MessageCrypto
    class Invalid < StandardError; end

    def initialize(config)
      @appid = config.fetch(:appid)
      @token = config.fetch(:token)
      @key = Base64.strict_decode64("#{config.fetch(:encoding_aes_key)}=")
      raise WechatPlatform::Error, "消息加解密 Key 无效" unless @key.bytesize == 32
    rescue ArgumentError
      raise WechatPlatform::Error, "消息加解密 Key 无效", cause: nil
    end

    def encrypt(xml)
      timestamp, nonce = Time.current.to_i.to_s, SecureRandom.hex(8)
      frame = SecureRandom.random_bytes(16) + [xml.bytesize].pack("N") + xml.b + @appid.b
      padding = 32 - frame.bytesize % 32
      cipher = OpenSSL::Cipher.new("aes-256-cbc").encrypt
      cipher.key = @key
      cipher.iv = @key.byteslice(0, 16)
      cipher.padding = 0
      encrypted = Base64.strict_encode64(cipher.update(frame + padding.chr * padding) + cipher.final)
      signature = Digest::SHA1.hexdigest([@token, timestamp, nonce, encrypted].sort.join)
      "<xml><Encrypt><![CDATA[#{encrypted}]]></Encrypt><MsgSignature><![CDATA[#{signature}]]></MsgSignature>" \
        "<TimeStamp>#{timestamp}</TimeStamp><Nonce><![CDATA[#{nonce}]]></Nonce></xml>"
    end

    def decrypt(encrypted, timestamp:, nonce:, signature:)
      raise Invalid if [ encrypted, timestamp, nonce, signature ].any?(&:blank?)
      raise Invalid if (Time.current.to_i - Integer(timestamp, 10)).abs > 600
      expected = Digest::SHA1.hexdigest([ @token, timestamp, nonce, encrypted ].sort.join)
      raise Invalid unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)
      cipher = OpenSSL::Cipher.new("aes-256-cbc").decrypt
      cipher.key = @key
      cipher.iv = @key.byteslice(0, 16)
      cipher.padding = 0
      plain = cipher.update(Base64.strict_decode64(encrypted)) + cipher.final
      padding = plain.getbyte(-1)
      raise Invalid unless padding.between?(1, 32) && plain.end_with?(padding.chr * padding)
      frame = plain.byteslice(0, plain.bytesize - padding)
      raise Invalid unless frame.bytesize >= 20
      length = frame.byteslice(16, 4).unpack1("N")
      raise Invalid unless frame.byteslice(20 + length..) == @appid
      frame.byteslice(20, length)
    rescue ArgumentError, OpenSSL::Cipher::CipherError
      raise Invalid, cause: nil
    end
  end
end
