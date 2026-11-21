<script setup>
import { onShow } from '@dcloudio/uni-app'
import { checkAppAccess } from '@/utils/app-access.js'

onShow(checkAppAccess)
</script>

<style lang="scss">
page {
  background-color: #fff;
  font-size: $uni-font-size-base;
}
</style>
