<script setup>
import { ref } from 'vue'
import { onLoad } from '@dcloudio/uni-app'
import { findDoctor } from '@/mock/doctors.js'
import { getBookingSchedule, getBookingSlots } from '@/mock/booking-schedule.js'
import { session } from '@/mock/session.js'
import { canOpenBooking } from '@/utils/booking-navigation.js'
import SlotPicker from './components/slot_picker.vue'

const doctor = ref(null)
const withDepartment = ref(false)
const schedule = ref([])
const date = ref('')
const slot = ref('')
const picking = ref(false)
const phone = ref('')
const name = ref('')
const sex = ref('')
const age = ref('')
const symptoms = ref('')

onLoad(options => {
  if (!canOpenBooking('form', options)) return
  doctor.value = findDoctor(options.id)
  if (!doctor.value) return
  withDepartment.value = options.department === '1'
  schedule.value = getBookingSchedule()
  date.value = schedule.value.find(day => day.date === options.date)?.date || schedule.value[0].date
  phone.value = session.value.phone
})

function selectTime() {
  uni.hideKeyboard()
  schedule.value = getBookingSchedule()
  picking.value = true
}

function setTime(selection) {
  date.value = selection.date
  slot.value = selection.slot
  picking.value = false
}

function notify(title) {
  uni.showToast({ title, icon: 'none' })
}

function phoneFailed() {
  notify('获取失败，请联系管理员')
}

function setPhone(result) {
  // 原生面板只返回授权码。尚未接入服务端换号时，保留原值。
  if (result.phone) phone.value = result.phone
  else phoneFailed()
}

function confirmBooking() {
  const day = getBookingSchedule().find(item => item.date === date.value)
  const available = getBookingSlots(day, doctor.value.id).some(item => item.label === slot.value && item.remaining > 0)
  if (!available) return notify(slot.value ? '请重新选择可预约时段' : '请选择时段')
  if (!phone.value) return notify('请获取预约电话')
  if (!name.value.trim()) return notify('请输入就诊人姓名')
  if (!sex.value) return notify('请选择性别')
  if (!/^\d{1,3}$/.test(age.value)) return notify('请输入就诊人年龄')
  notify('表单校验通过，当前为模拟预约')
}
</script>

<template>
  <view class="booking-form">
    <view class="header"><custom-page-header title="预约挂号" back /></view>
    <view v-if="doctor" class="form-content">
      <view class="panel">
        <view class="panel-title">门诊服务</view>
        <view class="row"><text>预约医生</text><text>{{ doctor.name }}</text></view>
        <view class="row date-row" aria-role="button" @tap="selectTime">
          <view>预约日期<text class="required">*</text></view><text>{{ date }}</text>
        </view>
        <view class="row time-row" aria-role="button" @tap="selectTime">
          <view>预约时段<text class="required">*</text></view><text>{{ slot || '请选择时段' }}</text>
        </view>
        <custom-phone-authorization label="获取预约电话" @authorized="setPhone" @denied="phoneFailed">
          <view class="row phone-row"><view>预约电话<text class="required">*</text></view><text>{{ phone || '获取手机号' }}</text></view>
        </custom-phone-authorization>
        <view v-if="withDepartment" class="row"><text>科室</text><text>{{ doctor.department }}</text></view>
        <view class="row last"><text>挂号费</text><text>¥{{ doctor.fee }}</text></view>
      </view>
      <view class="panel patient">
        <view class="panel-title">添加就诊人信息</view>
        <view class="row"><view>姓名<text class="required">*</text></view>
          <input v-model="name" aria-label="就诊人姓名" placeholder="请输入就诊人姓名" />
        </view>
        <view class="row"><view>性别<text class="required">*</text></view>
          <radio-group class="sex" aria-label="性别" @change="sex = $event.detail.value">
            <label v-for="value in ['男', '女']" :key="value"><radio :value="value" :checked="sex === value" color="#62b443" />{{ value }}</label>
          </radio-group>
        </view>
        <view class="row"><view>年龄<text class="required">*</text></view>
          <input v-model="age" type="number" :maxlength="3" aria-label="就诊人年龄" placeholder="请输入就诊人年龄" />
        </view>
        <view class="symptoms">症状描述
          <view v-if="picking" class="description">{{ symptoms }}</view>
          <textarea v-else v-model="symptoms" class="description" placeholder="请输入" aria-label="症状描述" :maxlength="-1" />
        </view>
      </view>
      <button class="submit" hover-class="none" @tap="confirmBooking">确定预约</button>
      <SlotPicker v-if="picking" :schedule="schedule" :doctor-id="doctor.id" :date="date" :slot="slot"
        @confirm="setTime" @cancel="picking = false" />
    </view>
    <view v-else class="unavailable">暂无该医生信息</view>
  </view>
</template>

<style scoped>
.booking-form { min-height: 100vh; background: #f4f4f6; color: #111; font-size: 28rpx; }
.header { position: sticky; top: 0; z-index: 4; background: #f8f8f8; }
.form-content { padding: 20rpx 20rpx max(32rpx,env(safe-area-inset-bottom)); }
.panel { padding: 28rpx 19rpx 20rpx; border-radius: 16rpx; background: #fff; }
.panel-title { display: flex; align-items: center; gap: 12rpx; margin-left: -19rpx; height: 60rpx; }
.panel-title::before { content: ''; width: 8rpx; height: 26rpx; border-radius: 5rpx; background: #7299ee; }
.row { display: flex; justify-content: space-between; align-items: center; box-sizing: border-box; min-height: 100rpx; padding-right: 8rpx; border-bottom: 1rpx solid #eee; }
.row.last { border: 0; }
.required { color: #b44e4e; font-size: 24rpx; }
.patient { margin-top: 34rpx; }
input { flex: 1; min-width: 0; margin-left: 20rpx; height: 68rpx; text-align: right; font-size: 28rpx; }
.sex, .sex label { display: flex; align-items: center; }
.sex { gap: 24rpx; }
.sex radio { transform: scale(.85); }
.symptoms { padding-top: 34rpx; }
.description { display: block; box-sizing: border-box; width: 100%; height: 150rpx; margin-top: 10rpx; padding: 26rpx; border: 2rpx solid #ddd; border-radius: 8rpx; font-size: 28rpx; }
.submit { margin: 34rpx 0 0; border-radius: 16rpx; background: #5da6e6; color: #fff; font-size: 26rpx; line-height: 64rpx; }
.submit::after { border: 0; }
.unavailable { padding: 40rpx; text-align: center; color: #888; }
</style>
