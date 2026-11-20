<script setup>
import { computed, ref } from 'vue'
import { onLoad } from '@dcloudio/uni-app'
import { allowedActions, bookingStatus, statusLabels, updateAppointment } from '@/mock/appointments.js'
import { session } from '@/mock/session.js'
import { useAppointmentRecords } from './appointment-records.js'

const { records, now, error, refresh } = useAppointmentRecords()
const no = ref('')
const showResult = ref(false)
const dialog = ref('')
onLoad(options => {
  no.value = options.no || ''
  showResult.value = options.created === '1'
})
const item = computed(() => records.value.find(row => row.no === no.value))
const status = computed(() => item.value && bookingStatus(item.value, now.value))
const actions = computed(() => item.value ? allowedActions(item.value, now.value) : [])
const success = computed(() => status.value === 'confirmed' && showResult.value)
const icons = {
  unpaid: '◷', confirming: '◷', reviewing: '◷', refunding: '◷',
  confirmed: '✓', completed: '✓', refunded: '✓', canceled: '−', closed: '−', rejected: '!', paymentFailed: '!',
}
const subtitles = {
  unpaid: '支付后确认预约', paymentFailed: '本次模拟支付未成功，可重新支付',
  confirming: '正在确认支付结果，请稍候', confirmed: '请按预约时段就诊',
  canceled: '本次预约已取消', closed: '预约时段已开始，支付已关闭', completed: '本次就诊时段已结束',
  reviewing: '退号申请已提交，正在等待审核', refunding: '审核已通过，正在处理模拟退款',
  refunded: '本次预约已退号', rejected: '本次模拟审核设为不通过，原预约仍有效',
}
const dialogs = {
  pay: { title: '模拟支付', cancel: '暂不支付', confirm: '确认支付' },
  cancel: { title: '取消预约', copy: '确定取消这次预约吗？', cancel: '保留预约', confirm: '确定取消' },
  refund: { title: '申请退号', copy: '确定申请退号吗？可在预约详情查看退款进度。', cancel: '保留预约', confirm: '确认申请' },
}
const prompt = computed(() => dialogs[dialog.value])
function confirmAction() {
  const action = dialog.value
  if (!action) return
  dialog.value = ''
  try {
    updateAppointment(session.value?.phone, no.value, action)
    if (action === 'pay') showResult.value = true
  } catch (err) {
    uni.showToast({ title: err.message || '操作失败，请重试', icon: 'none' })
  }
  refresh()
}
function viewRecords() {
  const pages = getCurrentPages()
  if (pages[pages.length - 2]?.route === 'pages/ucenter/appointments') uni.navigateBack()
  else uni.redirectTo({ url: '/pages/ucenter/appointments' })
}
</script>

<template>
  <view class="detail-page">
    <view class="header"><custom-page-header title="预约详情" back /></view>
    <view v-if="error" class="missing" aria-role="button" @tap="refresh">{{ error }}</view>
    <view v-else-if="!item" class="missing">暂无该预约记录</view>
    <view v-else class="content">
      <view class="card status-card" role="status">
        <view class="symbol" :class="{ waiting: icons[status] === '◷' }">{{ icons[status] }}</view>
        <view><view class="status-title">{{ success ? '预约成功' : statusLabels[status] }}</view>
          <view class="subtitle">{{ subtitles[status] }}</view></view>
      </view>
      <view class="card service">
        <view class="section-title">门诊服务</view>
        <view class="row"><text>预约医生</text>{{ item.doctor }}</view>
        <view class="row"><text>科室</text>{{ item.department }}</view>
        <view class="row"><text>就诊人</text>{{ item.patient.name }}</view>
        <view class="row"><text>预约日期</text>{{ item.date }}</view>
        <view class="row"><text>预约时段</text>{{ item.slot }}</view>
        <view class="row"><text>挂号费</text>¥{{ item.fee }}</view>
        <view v-if="['refunding','refunded'].includes(status)" class="row"><text>{{ status === 'refunded' ? '已退金额' : '退款金额' }}</text>¥{{ item.fee }}</view>
      </view>
      <view class="number">模拟预约单号　{{ item.no }}</view>
      <view class="footer">
        <button v-if="actions.includes('cancel') && !success" class="secondary" @tap="dialog = 'cancel'">取消预约</button>
        <button v-if="actions.includes('refund') && !success" class="secondary" @tap="dialog = 'refund'">申请退号</button>
        <button v-if="actions.includes('pay')" class="primary" @tap="dialog = 'pay'">去支付 ¥{{ item.fee }}</button>
        <button v-else class="primary" @tap="viewRecords">查看预约记录</button>
      </view>
      <view v-if="prompt" class="mask" @touchmove.stop.prevent>
        <view class="dialog" aria-role="dialog" :aria-label="prompt.title">
          <view class="dialog-title">{{ prompt.title }}</view>
          <view class="message">{{ dialog === 'pay' ? '本地模拟支付 ¥' + item.fee + '，不会实际扣款。' : prompt.copy }}</view>
          <view class="choices">
            <button @tap="dialog = ''">{{ prompt.cancel }}</button><button class="accept" @tap="confirmAction">{{ prompt.confirm }}</button>
          </view>
        </view>
      </view>
    </view>
  </view>
</template>

<style scoped>
.detail-page { min-height: 100vh; color: #111; background: #f4f4f6; font-size: 28rpx; }
.header { position: sticky; top: 0; z-index: 2; background: #fff; }
.content { padding: 24rpx 22rpx calc(144rpx + env(safe-area-inset-bottom)); }
.card { background: white; border-radius: 18rpx; }
.status-card { display: flex; align-items: center; gap: 22rpx; padding: 34rpx 28rpx; margin-bottom: 22rpx; }
.symbol { flex: none; width: 60rpx; height: 60rpx; border: 4rpx solid #5ba7e5; border-radius: 50%; line-height: 60rpx; text-align: center; font-size: 42rpx; color: #5ba7e5; }
.symbol.waiting { color: #c18431; border-color: #c18431; }
.status-title, .dialog-title { font-weight: 600; font-size: 34rpx; }
.subtitle { margin-top: 8rpx; color: #777; font-size: 25rpx; }
.service { padding: 12rpx 24rpx; }
.section-title { display: flex; align-items: center; gap: 12rpx; padding: 22rpx 0; font-size: 30rpx; }
.section-title::before { content: ''; width: 7rpx; height: 28rpx; border-radius: 4rpx; background: #7299ee; }
.row { display: flex; align-items: center; justify-content: space-between; min-height: 84rpx; gap: 20rpx; border-top: 1rpx solid #eee; }
.row text { color: #555; }
.number, .missing { margin: 24rpx 10rpx; color: #777; font-size: 23rpx; }
.missing { text-align: center; }
.footer { position: fixed; z-index: 1; bottom: 0; left: 0; right: 0; display: flex; gap: 14rpx; background: #f4f4f6; padding: 16rpx 24rpx calc(24rpx + env(safe-area-inset-bottom)); }
.footer button { margin: 0; line-height: 76rpx; font-size: 28rpx; border-radius: 12rpx; }
.primary { flex: 2; background: #5ba7e5; color: white; }
.secondary { flex: 1; background: white; color: #333; }
.primary::after, .choices button::after { border: 0; }
.mask { position: fixed; z-index: 5; inset: 0; display: flex; justify-content: center; align-items: center; background: rgba(0,0,0,.43); }
.dialog { width: 535rpx; max-width: 84vw; text-align: center; background: white; border-radius: 18rpx; overflow: hidden; }
.dialog-title { margin: 32rpx 20rpx 18rpx; font-size: 30rpx; }
.message { padding: 0 36rpx 28rpx; color: #555; font-size: 26rpx; line-height: 1.55; }
.choices { display: flex; border-top: 1rpx solid #eee; }
.choices button { flex: 1; margin: 0; line-height: 82rpx; font-size: 28rpx; background: white; color: #666; border-radius: 0; }
.choices .accept { color: #448dc6; border-left: 1rpx solid #eee; }
</style>
