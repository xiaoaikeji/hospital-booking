<script setup>
import { computed, ref, watch } from 'vue'
import { onHide, onLoad, onShow, onUnload } from '@dcloudio/uni-app'
import { allowedActions, updateAppointment } from '@/mock/appointments.js'
import { cancelPendingAppointment, checkAppointmentPayment, newBookingKey, requestAppointmentReturn, startAppointmentPayment } from '@/request/appointments.js'
import { demoMode, profile, signedIn } from '@/store/session.js'
import { requestWechatPayment } from '@/utils/wechat-pay.js'
import { recordStatus, recordStatusLabel, useAppointmentRecords } from './appointment-records.js'

const no = ref('')
const { records, now, error, loading, refresh, replace } = useAppointmentRecords(no)
const showResult = ref(false)
const dialog = ref('')
const busy = ref(false)
const visible = ref(false)
const waitingPayment = ref(false)
const checkedOnOpen = ref(false)
let refundKey
let poll
let progressRevision = 0
onLoad(options => {
  no.value = options.no || ''
  showResult.value = options.created === '1'
})
onShow(() => {
  checkedOnOpen.value = false
  visible.value = true
})
function stopPolling() {
  progressRevision++
  visible.value = false
  clearTimeout(poll)
}
onHide(stopPolling)
onUnload(stopPolling)
const item = computed(() => records.value[0])
const pending = computed(() => !demoMode && item.value?.status === 'pending_payment')
const secondsLeft = computed(() => Math.max(0,
  Math.ceil((item.value?.paymentExpiresAt - (now.value + item.value?.serverOffset)) / 1000)) || 0)
const countdown = computed(() => [Math.floor(secondsLeft.value / 60), secondsLeft.value % 60]
  .map(part => String(part).padStart(2, '0')).join(':'))
const closing = computed(() => pending.value && (item.value.paymentClosing || !secondsLeft.value))
const activeReturn = computed(() => item.value?.refunds?.filter(refund => refund.kind === 'cancel').slice(-1)[0])
const status = computed(() => {
  if (!item.value || demoMode) return item.value && recordStatus(item.value, now.value)
  if (closing.value) return 'closing'
  if (pending.value && (waitingPayment.value || item.value.paymentChecking)) return 'confirming'
  if (item.value.status === 'cancelled' && activeReturn.value) {
    if (activeReturn.value.status === 'processing') return 'refunding'
    if (activeReturn.value.status === 'succeeded' && activeReturn.value.amount) return 'refunded'
  }
  return item.value.status
})
const statusLabel = computed(() => ({
  closing: '关单核实中', confirming: '正在确认支付结果', refunding: '退款处理中', refunded: '已退款',
})[!demoMode && status.value] || (item.value && recordStatusLabel(item.value, now.value)))
const actions = computed(() => {
  if (!item.value) return []
  if (demoMode) return allowedActions(item.value, now.value)
  const operations = []
  if (item.value.canPay && status.value === 'pending_payment') operations.push('pay')
  if (item.value.canCancel && !closing.value) operations.push('cancel')
  if (item.value.canReturn) operations.push('refund')
  return operations
})
const success = computed(() => status.value === 'confirmed' && showResult.value)
const icons = {
  unpaid: '◷', confirming: '◷', reviewing: '◷', refunding: '◷', pending_payment: '◷', closing: '◷', cancel_requested: '◷',
  confirmed: '✓', completed: '✓', refunded: '✓', canceled: '−', cancelled: '−', closed: '−', rejected: '!', paymentFailed: '!',
}
const subtitles = {
  unpaid: '支付后确认预约', paymentFailed: '本次模拟支付未成功，可重新支付',
  confirming: '微信结果返回后会更新预约', confirmed: '请按预约时段就诊',
  pending_payment: '支付后确认预约', closing: '核实微信支付结果后更新预约', cancel_requested: '审核期间保留原预约',
  canceled: '本次预约已取消', closed: '预约时段已开始，支付已关闭',
  reviewing: '退号申请已提交，正在等待审核', refunding: '审核已通过，正在处理模拟退款',
  refunded: '本次预约已退号', rejected: '本次模拟审核设为不通过，原预约仍有效',
}
const dialogs = {
  pay: { title: '模拟支付', cancel: '暂不支付', confirm: '确认支付' },
  cancel: { title: '取消预约', copy: '确定取消这次预约吗？', cancel: '保留预约', confirm: '确定取消' },
  refund: { title: '申请退号', copy: '确定申请退号吗？可在预约详情查看退款进度。', cancel: '保留预约', confirm: '确认申请' },
}
const subtitle = computed(() => {
  if (!demoMode && status.value === 'completed') return '医院已登记就诊'
  if (!demoMode && status.value === 'refunding') return '微信正在处理退款'
  if (demoMode && status.value === 'completed') return '本次就诊时段已结束'
  return subtitles[status.value]
})
const prompt = computed(() => {
  const copy = dialogs[dialog.value]
  if (!demoMode && dialog.value === 'refund' && item.value?.fee === '0') {
    return { ...copy, copy: '确定申请退号吗？可在预约详情查看办理结果。' }
  }
  return copy
})

const needsRefresh = computed(() => visible.value && !demoMode && signedIn.value && !busy.value && !!item.value &&
  ((pending.value && ((!checkedOnOpen.value && item.value.paymentStarted) || item.value.paymentChecking || closing.value || waitingPayment.value)) ||
    ['requested', 'approved', 'processing'].includes(item.value.refundStatus)))
watch(needsRefresh, scheduleRefresh)
function scheduleRefresh() {
  clearTimeout(poll)
  if (needsRefresh.value) poll = setTimeout(refreshProgress, 4000)
}
async function refreshProgress() {
  if (!needsRefresh.value) return
  const started = progressRevision
  try {
    if (pending.value) {
      const result = await checkAppointmentPayment(no.value)
      if (started === progressRevision && visible.value && signedIn.value && !busy.value) applyPaymentResult(result)
    } else {
      await refresh()
    }
  } catch {
    // Leave the last confirmed state visible during a temporary connection error.
  } finally {
    scheduleRefresh()
  }
}

function applyPaymentResult(result) {
  replace(result)
  checkedOnOpen.value = true
  if (result.paymentStatus === 'paid' && waitingPayment.value) showResult.value = true
  waitingPayment.value = result.status === 'pending_payment' && result.paymentChecking
}

async function pay() {
  if (demoMode) {
    dialog.value = 'pay'
    return
  }
  if (busy.value) return
  progressRevision++
  busy.value = true
  try {
    const result = await startAppointmentPayment(no.value)
    const { cashier, payment } = await requestWechatPayment(result.payment_no, result.payment_params, () => checkAppointmentPayment(no.value))
    if (!signedIn.value) return
    if (payment.paymentStatus === 'paid') showResult.value = true
    applyPaymentResult(payment)
    if (cashier === 'returned' && payment.status === 'pending_payment') waitingPayment.value = true
    if (cashier === 'failed' && payment.status === 'pending_payment' && !waitingPayment.value) {
      uni.showToast({ title: '未完成支付，可继续付款', icon: 'none' })
    }
  } catch (err) {
    if (!signedIn.value) return
    if (err.code === 'payment_unavailable' || err.code === 'appointment_operation_unavailable') {
      await refresh()
    } else {
      waitingPayment.value = true
    }
    uni.showToast({ title: err.message || '暂时无法确认支付结果', icon: 'none' })
  } finally {
    busy.value = false
  }
}

async function confirmAction() {
  const action = dialog.value
  if (!action || busy.value) return
  progressRevision++
  dialog.value = ''
  busy.value = true
  try {
    if (demoMode) {
      updateAppointment(profile.value?.user_no, no.value, action)
      if (action === 'pay') showResult.value = true
      await refresh()
    } else if (action === 'cancel') {
      const result = await cancelPendingAppointment(no.value)
      if (signedIn.value) applyPaymentResult(result)
    } else if (action === 'refund') {
      refundKey ||= newBookingKey()
      const result = await requestAppointmentReturn(no.value, refundKey)
      refundKey = undefined
      if (signedIn.value) replace(result)
    }
  } catch (err) {
    uni.showToast({ title: err.message || '操作失败，请重试', icon: 'none' })
    if (err.statusCode === 422) await refresh()
  } finally {
    busy.value = false
  }
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
    <view v-if="loading" class="missing" role="status">加载中...</view>
    <view v-else-if="error" class="missing" aria-role="button" @tap="refresh">{{ error }}</view>
    <view v-else-if="!item" class="missing">暂无该预约记录</view>
    <view v-else class="content">
      <view class="card status-card" role="status">
        <view class="symbol" :class="{ waiting: icons[status] === '◷' }">{{ icons[status] }}</view>
        <view><view class="status-title">{{ success ? '预约成功' : statusLabel }}</view>
          <view v-if="subtitle" class="subtitle">{{ subtitle }}</view>
          <view v-if="pending && secondsLeft && !closing" class="subtitle">剩余付款时间 {{ countdown }}</view>
          <view v-if="pending && !item.originalPaymentApp && !closing" class="subtitle">请在原预约小程序继续支付</view>
        </view>
      </view>
      <view class="card service">
        <view class="section-title">门诊服务</view>
        <view class="row"><text>预约医生</text>{{ item.doctor }}</view>
        <view class="row"><text>科室</text>{{ item.department }}</view>
        <view class="row"><text>就诊人</text><view>{{ item.patient.name }}<text v-if="!demoMode" class="patient-meta"> · {{ item.patient.sex }} · {{ item.patient.age }} 岁</text></view></view>
        <view class="row"><text>本次联系电话</text>{{ item.phone }}</view>
        <view class="row"><text>预约日期</text>{{ item.date }}</view>
        <view class="row"><text>预约时段</text>{{ item.slot }}</view>
        <view v-if="item.address" class="row"><text>就诊地址</text><view>{{ item.address }}</view></view>
        <view class="row"><text>挂号费</text>¥{{ item.fee }}</view>
        <view v-if="!demoMode && item.fee !== '0' && item.paymentStatus === 'paid'" class="row"><text>实付</text>¥{{ item.paid }}</view>
        <view v-if="!demoMode && item.symptoms" class="row"><text>症状描述</text><view>{{ item.symptoms }}</view></view>
        <view v-if="demoMode && ['refunding','refunded'].includes(status)" class="row"><text>{{ status === 'refunded' ? '已退金额' : '退款金额' }}</text>¥{{ item.fee }}</view>
      </view>
      <view v-if="item.refunds?.length" class="card service refund-history">
        <view class="section-title">退号与退款记录</view>
        <view v-for="refund in item.refunds" :key="refund.id" class="refund-line">
          <view class="refund-heading"><text>{{ refund.kind === 'cancel' ? '退号' : '退差价' }}</text><text>{{ refund.status_label }}</text></view>
          <view v-if="refund.amount" class="refund-note">申请金额 ¥{{ refund.amount }}</view>
          <view v-if="refund.cash != null" class="refund-note">已退现金 ¥{{ refund.cash }}</view>
          <view v-else-if="refund.amount && refund.status === 'succeeded'" class="refund-note">现金金额待核对</view>
          <view v-if="refund.reason" class="refund-note">{{ refund.reason }}</view>
          <view v-if="refund.review_note" class="refund-note">{{ refund.review_note }}</view>
        </view>
      </view>
      <view class="number">{{ demoMode ? '模拟预约单号' : '预约号' }}　{{ item.no }}</view>
      <view class="footer">
        <button v-if="actions.includes('cancel') && !success" class="secondary" :disabled="busy" @tap="dialog = 'cancel'">取消预约</button>
        <button v-if="actions.includes('refund') && !success" class="secondary" :disabled="busy" @tap="dialog = 'refund'">申请退号</button>
        <button v-if="actions.includes('pay')" class="primary" :disabled="busy" @tap="pay">{{ busy ? '核对支付中…' : '去支付 ¥' + item.fee }}</button>
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
.row > text { flex: none; }
.row > view { text-align: right; overflow-wrap: anywhere; white-space: pre-wrap; }
.patient-meta { font-size: 25rpx; }
.refund-history { margin-top: 22rpx; }
.refund-line { padding: 22rpx 0; border-top: 1rpx solid #eee; }
.refund-heading { display: flex; justify-content: space-between; gap: 20rpx; font-weight: 600; }
.refund-note { margin-top: 10rpx; color: #555; font-size: 25rpx; white-space: pre-wrap; overflow-wrap: anywhere; }
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
