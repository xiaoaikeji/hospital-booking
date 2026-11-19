import { ref } from 'vue'

// 微信会保留底栏页面，首页的「预约挂号」入口需要重新选中「按科室」。
export const bookingMode = ref('department')
