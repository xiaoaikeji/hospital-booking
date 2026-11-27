import { requestApp, wechatAppId } from './http.js'

export function loadDoctors(filters) {
  return requestApp(wechatAppId(), 'doctors', { data: filters })
}
