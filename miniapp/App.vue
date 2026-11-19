<script setup>
import { onLaunch } from '@dcloudio/uni-app'
import { loadAppConfiguration } from '@/request/http.js'
import { appConfiguration } from '@/store/app-configuration.js'

onLaunch(() => {
  loadAppConfiguration(config => { appConfiguration.value = config })
})
</script>

<style lang="scss">
page {
  background-color: #fff;
  font-size: $uni-font-size-base;
}
</style>
