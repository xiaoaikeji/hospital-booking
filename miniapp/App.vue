<script setup>
import { onShow } from '@dcloudio/uni-app'
import { checkAppAccess } from '@/utils/app-access.js'
import { noteEntry } from '@/store/session.js'

onShow(options => {
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
