import { defineConfig, loadEnv } from 'vite'
import uni from '@dcloudio/vite-plugin-uni'
import { apiTarget } from './config/api.js'

function isHttpsAddress(address) {
  try {
    const url = new URL(address)
    return url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash
  } catch {
    return false
  }
}

export default defineConfig(() => {
  const release = process.env.NODE_ENV === 'production'
  const target = apiTarget(release)
  // 开发编译也可以连接正式后台，因此按接口目标读取对应的 .env 文件。
  const env = loadEnv(target, __dirname, 'VITE_BOOKING_API_ORIGIN')
  const origin = (env.VITE_BOOKING_API_ORIGIN || '').trim().replace(/\/+$/, '')
  if (target === 'production' && !isHttpsAddress(origin)) {
    throw new Error('请在 miniapp/.env.production.local 设置 VITE_BOOKING_API_ORIGIN 为部署医院的 HTTPS 后台地址')
  }

  return {
    plugins: [uni()],
    define: { 'process.env.VITE_BOOKING_API_ORIGIN': JSON.stringify(origin) },
  }
})
