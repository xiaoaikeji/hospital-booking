<script setup>
import { computed, nextTick, ref } from 'vue'
import { onLoad, onShow } from '@dcloudio/uni-app'
import { bookingDepartments, directoryDemoMode, findBookingDoctor } from '@/store/booking-directory.js'
import { getBookingSchedule } from '@/mock/booking-schedule.js'
import { createAppointment, listPatients, newAppointmentNo } from '@/mock/appointments.js'
import { bindPhone, demoMode, readProfile } from '@/store/session.js'
import { canOpenBooking } from '@/utils/booking-navigation.js'
import { checkAppAccess } from '@/utils/app-access.js'
import SlotPicker from './components/slot_picker.vue'
import PatientPicker from './components/patient_picker.vue'

const bookingParams = ref(null)
const fromDemo = computed(() => directoryDemoMode || bookingParams.value?.demo === '1')
const doctor = computed(() => bookingParams.value && findBookingDoctor(bookingParams.value.id, fromDemo.value))
const departmentName = computed(() => {
  if (!doctor.value) return ''
  if (fromDemo.value) return bookingParams.value.department === '1' ? doctor.value.department : ''
  const id = bookingParams.value.department_id
  return doctor.value.department_ids.includes(id) ? bookingDepartments.value.find(department => department.id === id)?.name : ''
})
const schedule = ref([])
const date = ref('')
const slot = ref('')
const picking = ref(false)
const phone = ref('')
const needsBinding = ref(false)
const binding = ref(false)
const name = ref('')
const sex = ref('')
const age = ref('')
const symptoms = ref('')
const patients = ref([])
const patientId = ref('')
const choosingPatient = ref(false)
const savePatient = ref(false)
const submitting = ref(false)
const createdNo = ref('')
let requestNo = ''
let openedDetail = false

onLoad(async options => {
  if (!await canOpenBooking('form', options)) return
  bookingParams.value = options
  if (!fromDemo.value) {
    date.value = options.date || ''
    return
  }
  if (!doctor.value) return
  schedule.value = getBookingSchedule()
  date.value = schedule.value.find(day => day.date === options.date)?.date || schedule.value[0].date
  try {
    const user = await readProfile()
    if (!phone.value && user?.mobile) phone.value = user.mobile
    if (demoMode && user) patients.value = listPatients(user.user_no)
  } catch (error) {
    notify(error.message || '暂时无法读取本人资料')
  }
})

onShow(() => {
  if (bookingParams.value && !fromDemo.value) checkAppAccess()
  if (!openedDetail) return
  if (getCurrentPages().length > 1) uni.navigateBack()
  else uni.redirectTo({ url: '/pages/ucenter/appointments' })
})

async function choosePatient(id = '') {
  choosingPatient.value = false
  if (id && id === patientId.value) return
  if (symptoms.value.trim()) {
    const result = await uni.showModal({
      title: '切换就诊人', content: '切换就诊人将清空已填写的症状描述。',
      cancelText: '保留原文', confirmText: '切换',
    })
    if (!result.confirm) return
  }
  const patient = patients.value.find(item => item.id === id)
  patientId.value = id
  name.value = patient?.name || ''
  sex.value = patient?.sex || ''
  age.value = patient ? String(patient.age) : ''
  symptoms.value = ''
  savePatient.value = false
}

function openPatientPicker() {
  uni.hideKeyboard()
  choosingPatient.value = true
}

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

function phoneDenied() {
  needsBinding.value = false
  notify('已取消授权，预约内容已保留')
}

async function verifyPhone(result) {
  if (binding.value) return
  binding.value = true
  try {
    const user = await bindPhone(result)
    if (!phone.value) phone.value = user.mobile
    needsBinding.value = false
    notify('账号手机号已验证')
  } catch (error) {
    notify(error.message || '手机号验证失败，请重试')
  } finally {
    binding.value = false
  }
}

async function confirmBooking() {
  if (!fromDemo.value || submitting.value || binding.value || openedDetail) return
  if (!createdNo.value) {
    if (!slot.value) return notify('请选择时段')
    if (!name.value.trim()) return notify('请输入就诊人姓名')
    if (!sex.value) return notify('请选择性别')
    if (!/^\d{1,3}$/.test(age.value) || +age.value < 1 || +age.value > 200) return notify('请输入1至200之间的年龄')
  }
  submitting.value = true
  uni.hideKeyboard()
  try {
    if (!createdNo.value) {
      const user = await readProfile()
      if (!user) return notify('请先登录')
      if (user.booking_phone_required) {
        needsBinding.value = true
        await nextTick()
        uni.pageScrollTo({ selector: '#phone-binding', duration: 180 })
        return
      }
      const contact = phone.value.trim().replace(/[ -]/g, '')
      if (!/^\+?\d{6,15}$/.test(contact)) return notify('请输入有效的本次联系电话')
      if (!demoMode) return notify('医院预约受理尚未开放')
      requestNo ||= newAppointmentNo()
      const record = createAppointment(user.user_no, requestNo, {
        doctorId: doctor.value.id, date: date.value, slot: slot.value, phone: contact,
        name: name.value, sex: sex.value, age: age.value, symptoms: symptoms.value,
        patientId: patientId.value, savePatient: savePatient.value,
      })
      createdNo.value = record.no
    }
    await uni.navigateTo({ url: '/pages/ucenter/appointment_detail?created=1&no=' + createdNo.value })
    openedDetail = true
  } catch (error) {
    notify(createdNo.value ? '已创建预约，点击查看详情' : error.message || '提交失败，请重试')
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <view class="booking-form">
    <view class="header"><custom-page-header title="预约挂号" back /></view>
    <view v-if="doctor" class="form-content">
      <view class="panel service-panel">
        <view class="panel-title">门诊服务</view>
        <view class="row"><text>预约医生</text><text>{{ doctor.name }}</text></view>
        <view v-if="fromDemo" class="row date-row" aria-role="button" @tap="selectTime">
          <view>预约日期<text class="required">*</text></view><text>{{ date }}</text>
        </view>
        <view v-else-if="date" class="row"><text>预约日期</text><text>{{ date }}</text></view>
        <view v-if="fromDemo" class="row time-row" aria-role="button" @tap="selectTime">
          <view>预约时段<text class="required">*</text></view><text>{{ slot || '请选择时段' }}</text>
        </view>
        <view v-if="fromDemo" class="row phone-row"><view>本次联系电话<text class="required">*</text></view>
          <input v-model="phone" aria-label="本次联系电话" :maxlength="21" placeholder="请输入就诊联系电话" />
        </view>
        <view v-if="departmentName" class="row"><text>科室</text><text>{{ departmentName }}</text></view>
        <view class="row last"><text>挂号费</text><text>¥{{ doctor.fee }}</text></view>
      </view>
      <view v-if="fromDemo" class="panel patient">
        <view class="panel-title">添加就诊人信息
          <text v-if="patients.length" class="choose-patient" aria-role="button" @tap="openPatientPicker">选择就诊人 ›</text>
        </view>
        <view class="row"><view>姓名<text class="required">*</text></view>
          <input v-model="name" :disabled="!!patientId" aria-label="就诊人姓名" placeholder="请输入就诊人姓名" />
        </view>
        <view class="row"><view>性别<text class="required">*</text></view>
          <radio-group class="sex" aria-label="性别" @change="sex = $event.detail.value">
            <label v-for="value in ['男', '女']" :key="value"><radio :value="value" :disabled="!!patientId" :checked="sex === value" color="#62b443" />{{ value }}</label>
          </radio-group>
        </view>
        <view class="row"><view>年龄<text class="required">*</text></view>
          <input v-model="age" :disabled="!!patientId" type="number" :maxlength="3" aria-label="就诊人年龄" placeholder="请输入就诊人年龄" />
        </view>
        <checkbox-group v-if="demoMode && !patientId" class="save-patient" @change="savePatient = !!$event.detail.value.length">
          <label><checkbox value="save" :checked="savePatient" color="#5ba7e5" />保存为常用就诊人</label>
        </checkbox-group>
        <view class="symptoms">症状描述
          <view v-if="picking || choosingPatient" class="description">{{ symptoms }}</view>
          <textarea v-else v-model="symptoms" class="description" placeholder="请输入" aria-label="症状描述" :maxlength="-1" />
        </view>
      </view>
      <view class="demo-note">{{ demoMode ? '本地模拟预约，请使用虚构就诊资料' : '正式预约受理尚未开放' }}</view>
      <view v-if="fromDemo && needsBinding" id="phone-binding">
        <view class="binding-note">医院要求先验证账号手机号。本次联系电话可填写家属号码。</view>
        <custom-phone-authorization label="验证账号手机号" @authorized="verifyPhone" @denied="phoneDenied" @failed="notify('手机号授权失败，请重试')">
          <view class="submit bind-button">{{ binding ? '验证中…' : '验证账号手机号' }}</view>
        </custom-phone-authorization>
      </view>
      <button v-else-if="fromDemo" class="submit" hover-class="none" :disabled="submitting" @tap="confirmBooking">{{ submitting ? '确认中…' : createdNo ? '查看预约详情' : '确定预约' }}</button>
      <SlotPicker v-if="picking" :schedule="schedule" :doctor-id="doctor.id" :date="date" :selected-slot="slot"
        @confirm="setTime" @cancel="picking = false" />
      <PatientPicker v-if="choosingPatient" :patients="patients" :selected="patientId"
        @confirm="choosePatient" @add="choosePatient()" @cancel="choosingPatient = false" />
    </view>
    <view v-else class="unavailable">暂无该医生信息</view>
  </view>
</template>

<style scoped>
.booking-form { min-height: 100vh; background: #f4f4f6; color: #111; font-size: 28rpx; }
.header { position: sticky; top: 0; z-index: 4; background: #f8f8f8; }
.form-content { padding: 20rpx 20rpx max(32rpx,env(safe-area-inset-bottom)); }
.panel { padding: 28rpx 19rpx 20rpx; border-radius: 16rpx; background: #fff; }
.service-panel { padding-bottom: 0; }
.panel-title { display: flex; align-items: center; gap: 12rpx; margin-left: -19rpx; height: 60rpx; }
.panel-title::before { content: ''; width: 8rpx; height: 26rpx; border-radius: 5rpx; background: #7299ee; }
.row { display: flex; justify-content: space-between; align-items: center; box-sizing: border-box; min-height: 100rpx; padding-right: 8rpx; border-bottom: 1rpx solid #eee; }
.row.last { border-bottom-color: transparent; }
.required { color: #b44e4e; font-size: 24rpx; }
.patient { margin-top: 34rpx; }
.choose-patient { margin-left: auto; padding: 10rpx 8rpx; color: #438ac4; font-size: 25rpx; }
.save-patient { margin-top: 18rpx; color: #666; font-size: 24rpx; }
.save-patient checkbox { transform: scale(.8); }
.demo-note { margin: 24rpx 0 10rpx; color: #777; font-size: 22rpx; text-align: center; }
.binding-note { margin: 16rpx 0; color: #536777; font-size: 25rpx; }
.bind-button { text-align: center; }
input { flex: 1; min-width: 0; margin-left: 20rpx; height: 68rpx; text-align: right; font-size: 28rpx; }
.sex, .sex label { display: flex; align-items: center; }
.sex { gap: 24rpx; }
.sex radio { transform: scale(.85); }
.symptoms { padding-top: 34rpx; }
.description { display: block; box-sizing: border-box; width: 100%; height: 150rpx; margin-top: 10rpx; padding: 26rpx; border: 2rpx solid #ddd; border-radius: 8rpx; font-size: 28rpx; }
.submit { margin: 0; border-radius: 16rpx; background: #5da6e6; color: #fff; font-size: 26rpx; line-height: 64rpx; }
.submit::after { border: 0; }
.unavailable { padding: 40rpx; text-align: center; color: #888; }
</style>
