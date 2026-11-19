module WechatPlatform
  # 小程序可以设置的服务类目（getallcategories），整理成「一级分类 → 二级分类 → 资质方案 → 资质文件」。
  #
  # 要什么资质一律取微信返回的 qualify，这里不写死：exter_list 的每一项是一个资质方案（多个时选其一），
  # 方案里 inner_list 的每一项是一份要上传的资质文件，name 是资质名称，提交时原样作为 certicates 的 key。
  # 类目随主体类型不同，按应用缓存 6 小时：打开添加弹窗、提交时都不用每次请求微信。
  class CategoryCatalog
    CACHE_TTL = 6.hours

    def self.for(app, client)
      new(Rails.cache.fetch("wechat/apps/#{app.id}/category_catalog", expires_in: CACHE_TTL) { client.catalog })
    end

    def initialize(nodes)
      @firsts = nodes.select { |node| node["level"].to_i == 1 }
      @seconds = nodes.select { |node| node["level"].to_i == 2 }.group_by { |node| node["father"].to_s }
    end

    # 添加弹窗的选项：[{ "id", "name", "children" => [二级类目，见 entry] }]。
    # 已设置的二级类目（added 里的「一级ID-二级ID」）不再列出，二级都设置过的一级分类也不列。
    def options(added: [])
      @firsts.filter_map do |first|
        children = @seconds.fetch(first["id"].to_s, []).reject { |second| added.include?("#{first['id']}-#{second['id']}") }
        { "id" => first["id"], "name" => first["name"], "children" => children.map { |second| entry(second) } } if children.any?
      end
    end

    # 提交时按 ID 找二级类目，必须挂在这个一级分类下；找到时 entry 外加 first、first_name，找不到返回 nil。
    def find(first_id, second_id)
      first = @firsts.find { |node| node["id"].to_s == first_id.to_s }
      second = first && @seconds.fetch(first["id"].to_s, []).find { |node| node["id"].to_s == second_id.to_s }
      entry(second).merge("first" => first["id"], "first_name" => first["name"]) if second
    end

    private

    # { "id", "name", "plans" => [[{ "name", "url" }]], "remark" }；plans 为空就是不用资质。
    def entry(node)
      qualify = node["qualify"] || {}
      plans = Array(qualify["exter_list"]).map do |plan|
        Array(plan["inner_list"]).filter_map do |item|
          { "name" => item["name"].to_s, "url" => sample_url(item["url"]) } if item["name"].present?
        end
      end
      { "id" => node["id"], "name" => node["name"], "plans" => plans.reject(&:empty?), "remark" => qualify["remark"].to_s }
    end

    # 示例图做成页面上的「查看示例」链接，只认 http(s)。
    def sample_url(url)
      url.to_s if url.to_s.match?(%r{\Ahttps?://})
    end
  end
end
