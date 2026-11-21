<script setup>
import { onLaunch, onShow } from '@dcloudio/uni-app'
import { checkAppAccess } from '@/utils/app-access.js'
import { noteEntry, retryRevocations } from '@/store/session.js'

onLaunch(() => {
  uni.onNetworkStatusChange(({ isConnected }) => { if (isConnected) retryRevocations() })
})

onShow(options => {
  retryRevocations()
  checkAppAccess()
  noteEntry(options)
})
</script>

<style lang="scss">
page {
  background-color: #fff;
  font-size: $uni-font-size-base;
}
</style>
