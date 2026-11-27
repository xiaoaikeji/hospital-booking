<script>
// 重新启动小程序时重置，同一进程从首页或个人中心进入只播放一次。
let firstVisit = true
</script>

<script setup>
import { computed, ref } from 'vue'
import { onUnload } from '@dcloudio/uni-app'
import { demoMode } from '@/store/session.js'
import { recordStatus, recordStatusLabel, useAppointmentRecords } from './appointment-records.js'

const { records, now, error, loading: fetching, refresh } = useAppointmentRecords()
const cards = computed(() => records.value.map(item => ({
  ...item, status: recordStatus(item, now.value), statusLabel: recordStatusLabel(item, now.value),
})))
function openDetail(no) {
  uni.navigateTo({ url: '/pages/ucenter/appointment_detail?no=' + no })
}
const loading = ref(firstVisit)
let timer
if (firstVisit) {
  firstVisit = false
  timer = setTimeout(() => { loading.value = false }, 1500)
}
onUnload(() => clearTimeout(timer))
</script>

<template>
  <view class="appointments-page">
    <view class="appointments-header"><custom-page-header title="预约记录" back /></view>
    <view v-if="loading || fetching" class="record-loading" role="status">
      <view class="spinner">
        <view v-for="i in 12" :key="i" class="spoke" :style="{ transform: 'rotate(' + i * 30 + 'deg)', opacity: i / 12 }" />
      </view>
      <text>加载中...</text>
    </view>
    <view v-else-if="error" class="retry" aria-role="button" @tap="refresh">{{ error }}</view>
    <view v-else-if="cards.length" class="cards">
      <view v-for="item in cards" :key="item.no" class="record" aria-role="link" @tap="openDetail(item.no)">
        <view class="record-heading">
          <text class="doctor">{{ item.doctor }} · {{ item.department }}</text>
          <text class="state" :class="item.status">{{ item.statusLabel }}</text>
        </view>
        <view class="record-row"><text class="label">就诊人</text>{{ item.patient.name }}</view>
        <view class="record-row">{{ item.date }}　{{ item.slot }}</view>
        <view class="record-footer">
          <text>挂号费 ¥{{ item.fee }}</text>
          <text v-if="item.canPay || (demoMode && ['unpaid','paymentFailed'].includes(item.status))" class="pay-link">继续支付</text>
          <text v-else-if="item.refundStatus && item.refundStatus !== 'none'" class="state">{{ item.refundLabel }}</text>
          <text v-else class="detail-link">查看详情 ›</text>
        </view>
      </view>
    </view>
    <view v-else class="empty-card">
      <image class="empty-illustration" src="/static/ucenter/empty-appointments.jpg" mode="aspectFit" />
      <text class="empty-message">暂无预约记录</text>
    </view>
  </view>
</template>

<style scoped>
.appointments-page { min-height: 100vh; background: #f8f8f8; }
.appointments-header { position: sticky; top: 0; z-index: 1; background: #fff; }
.cards { padding: 24rpx 24rpx max(24rpx, env(safe-area-inset-bottom)); }
.record { margin-bottom: 20rpx; padding: 0 24rpx; border-radius: 18rpx; background: #fff; color: #222; font-size: 27rpx; }
.record-heading, .record-footer { display: flex; align-items: center; justify-content: space-between; gap: 12rpx; min-height: 84rpx; }
.doctor { padding-left: 14rpx; border-left: 7rpx solid #659fea; font-size: 29rpx; font-weight: 600; }
.state { flex: none; color: #666; font-size: 25rpx; }
.confirmed { color: #438bc7; }
.unpaid, .confirming, .reviewing, .refunding, .pending_payment, .cancel_requested { color: #a86810; }
.record-row, .record-footer { border-top: 1rpx solid #eee; }
.record-row { padding: 14rpx 0; }
.label { margin-right: 42rpx; color: #666; }
.pay-link { border: 1rpx solid #64a5d9; border-radius: 9rpx; padding: 5rpx 14rpx; color: #438bc7; font-size: 24rpx; }
.detail-link, .retry { color: #438bc7; }
.retry { padding: 68rpx 20rpx; text-align: center; }
.record-loading { display: flex; align-items: center; justify-content: center; gap: 62rpx; padding-top: 72rpx; font-size: 28rpx; color: #111; }
.spinner { position: relative; width: 90rpx; height: 90rpx; animation: spin 1s steps(12) infinite; }
.spoke { position: absolute; inset: 0; }
.spoke::before { content: ''; display: block; margin: 0 auto; width: 10rpx; height: 22rpx; border-radius: 50%; background: #60aae4; }
@keyframes spin { to { transform: rotate(360deg); } }
.empty-card { display: flex; flex-direction: column; align-items: center; box-sizing: border-box; margin: 30rpx; padding-top: 68rpx; min-height: 540rpx; border-radius: 16rpx; background: #fff; }
.empty-illustration { display: block; width: 372rpx; height: 333rpx; }
.empty-message { margin-top: 6rpx; color: #aaa; font-size: 30rpx; line-height: 46rpx; }
</style>
