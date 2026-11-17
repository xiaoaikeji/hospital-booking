# 固定每页 20 条，仅使用分页计算；不接受客户端自定义 limit，不引入 Pagy 默认 UI。
Pagy::OPTIONS[:limit] = 20
