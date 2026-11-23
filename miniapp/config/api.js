// 普通运行和扫码预览默认连开发后台。要联调正式后台，只改 API_TARGET 并重新运行。
// 发行时始终使用 production。
// 在 miniapp/.env.development.local 填开发地址，在 miniapp/.env.production.local 填医院正式地址。
// 两个文件都使用 VITE_BOOKING_API_ORIGIN。
const API_TARGET = 'development'

export function apiTarget(release) {
  if (release) return 'production'
  if (!['development', 'production'].includes(API_TARGET)) throw new Error('API_TARGET 只能选 development 或 production')
  return API_TARGET
}

// vite.config.js 从所选环境的 .env 文件读取地址，在编译时写入成品。
export const API_ORIGIN = process.env.VITE_BOOKING_API_ORIGIN || ''

export function buildApiUrl(appId, path) {
  return API_ORIGIN + '/api/apps/wechat/' + encodeURIComponent(appId) + '/' + path
}
