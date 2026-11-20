require "test_helper"

class Notifications::VariablesTest < ActiveSupport::TestCase
  test "只替换已登记变量，保留零和 false，支持字面量大括号且不二次解释数据" do
    fields = %w[amount enabled name].index_with { { "label" => "数据" } }
    rows = [ { "id" => "first", "type" => "text", "content" => { "text" => "{amount} {enabled} {name} {{name}}" } } ]
    rendered = Notifications::Variables.render(rows, fields: fields, data: { amount: 0, enabled: false, name: "{amount}" })
    assert_equal "0 false {amount} {name}", rendered.first.dig("content", "text")
    assert_equal "{amount} {enabled} {name} {{name}}", rows.first.dig("content", "text")
    assert_raises(Notifications::Error) { Notifications::Variables.render(rows, fields: fields, data: { amount: 0 }) }
  end

  test "可选数据不足时整行省略，实际快照按渠道字节上限保存且不破坏中文" do
    fields = { "name" => { "label" => "名称" }, "reason" => { "optional" => true } }
    rows = [ { "id" => "first", "type" => "text", "content" => { "text" => "名称：{name}\n原因：{reason}" } } ]
    result = Notifications::Variables.render(rows, fields: fields, data: { name: "活动" * 600 })
    assert result.first["truncated"]
    assert result.first.dig("content", "text").valid_encoding?
    assert_operator result.first.dig("content", "text").bytesize, :<=, 2048
    assert_not_includes result.first.dig("content", "text"), "原因："
    assert_raises(Notifications::Error) { Notifications::Variables.validate!([ { "type" => "text", "content" => { "text" => "{secret}" } } ], fields: fields) }
  end
end
