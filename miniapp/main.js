import { createSSRApp } from 'vue'
import App from './App.vue'
import { configurationStatus } from '@/store/app-configuration.js'
import { checkAppAccess, PAUSED_PAGE } from '@/utils/app-access.js'

export function createApp() {
  const app = createSSRApp(App)
  app.mixin({
    onShow() {
      if (this.$mpType !== 'page') return
      if (this.$scope.route === PAUSED_PAGE && configurationStatus.value === 'disabled') return
      checkAppAccess()
    },
  })
  return { app }
}
