require "ipaddr"

module IpLocation
  NON_PUBLIC = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
    192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
    224.0.0.0/4 240.0.0.0/4 2001::/23 2001:db8::/32 2002::/16 3fff::/20
  ].map { |range| IPAddr.new(range) }.freeze
  GLOBAL_V6 = IPAddr.new("2000::/3")
  CLIENTS = { "baidu" => BaiduMap::IpLocationClient, "tencent" => TencentMap::IpLocationClient }.freeze

  def self.public_address(input)
    text = input.to_s.strip
    return if text.empty? || text.length > 45 || text.include?("/") || text.include?("%")
    address = IPAddr.new(text).native
    return if address.ipv6? && !GLOBAL_V6.include?(address)
    address.to_s unless NON_PUBLIC.any? { |range| range.include?(address) }
  rescue IPAddr::Error
    nil
  end

  def self.from_request(request)
    peer = request.get_header("REMOTE_ADDR")
    return if peer.blank?
    proxies = Rails.application.config.action_dispatch.trusted_proxies.presence || ActionDispatch::RemoteIp::TRUSTED_PROXIES
    # A direct client cannot select its own location by supplying forwarding headers.
    public_address(proxies.any? { |range| range === peer } ? request.remote_ip : peer)
  rescue ActionDispatch::RemoteIp::IpSpoofAttackError, IPAddr::Error
    nil
  end

  def self.lookup(ip, settings: MapSettings.new)
    address = public_address(ip)
    return unless address && settings.key.present?
    CLIENTS.fetch(settings.provider).new.locate(address, settings.key)
  end

  def self.region_name(*candidates)
    candidates.each do |value|
      next unless value.is_a?(String)
      name = value.strip
      return name if name.present? && name.length <= 80 && !name.match?(/\A(?:none|null|unknown|0|未知)\z|[[:cntrl:]]/i)
    end
    nil
  end
end
