<script setup>
import { computed, nextTick, ref, watch } from 'vue'
import { onHide, onLoad, onShow, onUnload } from '@dcloudio/uni-app'
import { bookingDepartments, directoryDemoMode, findBookingDoctor } from '@/store/booking-directory.js'
import { bookingNotice, bookingSymptomsRequired, displayFreeFeeWhenFeeIsZero, displayHospitalAddress, hospitalProfile, refreshAppConfiguration } from '@/store/app-configuration.js'
import { createAppointment, newAppointmentNo } from '@/mock/appointments.js'
import { newBookingKey, submitAppointment } from '@/request/appointments.js'
import { bindPhone, demoMode, readProfile, requestForUser, signedIn } from '@/store/session.js'
import { canOpenBooking, NO_BOOKABLE_DEPARTMENT } from '@/utils/booking-navigation.js'
import { canUseApp, checkAppAccess } from '@/utils/app-access.js'
import { hospitalLocation, openHospitalLocation } from '@/utils/hospital-location.js'
import SlotPicker from './components/slot_picker.vue'
import PatientPicker from './components/patient_picker.vue'
import PatientFields from './components/patient_fields.vue'
import { loadPatients, patientValidationMessage } from './patient-profiles.js'
import { bookingSlotKey, bookingSlots, scheduleMessage, shiftBookable, useBookingCalendar } from './booking-calendar.js'

const bookingParams = ref(null)
const fromDemo = computed(() => directoryDemoMode || bookingParams.value?.demo === '1')
const doctor = computed(() => bookingParams.value && findBookingDoctor(bookingParams.value.id, fromDemo.value))
const feeText = computed(() => {
  const fee = doctor.value?.fee
  if (fee == null) return ''
  if (Number(fee) !== 0) return `¥${fee}`
  return displayFreeFeeWhenFeeIsZero.value ? '免费' : ''
})
const hospitalAddress = computed(() => displayHospitalAddress.value ? (hospitalProfile.value.address ?? '').trim() : '')
const hospitalCanNavigate = computed(() => !!hospitalLocation(hospitalProfile.value))
const departmentChoice = ref('')
const departments = computed(() => fromDemo.value ? [] :
  bookingDepartments.value.filter(department => doctor.value?.department_ids.includes(department.id)))
const sourceDepartment = computed(() => departments.value.find(department => department.id === bookingParams.value?.department_id))
const department = computed(() => sourceDepartment.value ||
  (departments.value.length === 1 ? departments.value[0] : departments.value.find(item => item.id === departmentChoice.value)))
const departmentName = computed(() => fromDemo.value
  ? (bookingParams.value?.department === '1' ? doctor.value?.department : '')
  : department.value?.name)
const chooseDepartment = computed(() => departments.value.length > 1 && !sourceDepartment.value)
const departmentIndex = computed(() => Math.max(0, departments.value.findIndex(item => item.id === departmentChoice.value)))
function setDepartment(event) {
  departmentChoice.value = departments.value[Number(event.detail.value)]?.id || ''
}
const { schedule, selectedDate, selectedDay, refresh, now, refreshClock } = useBookingCalendar(() => fromDemo.value)
const date = computed(() => selectedDay.value?.date || '')
const slotSelection = ref(null)
const slots = computed(() => bookingSlots(selectedDay.value, doctor.value?.id))
const selectedSlot = computed(() => {
  const selection = slotSelection.value
  if (!selection || selection.date !== date.value || selection.doctorId !== doctor.value?.id) return null
  if (fromDemo.value) return selection.slot
  const key = bookingSlotKey(selection.slot)
  return slots.value.find(slot => bookingSlotKey(slot) === key && shiftBookable(slot, now.value)) || null
})
const slotText = computed(() => (pendingBooking.value && slotSelection.value?.slot.label) ||
  selectedSlot.value?.label || (fromDemo.value || slots.value.length ? '请选择时段' : scheduleMessage.value))
const picking = ref(false)
const phone = ref('')
const needsBinding = ref(false)
const checkingBinding = ref(false)
const binding = ref(false)
const canAuthorizePhone = computed(() => {
  if (!needsBinding.value || checkingBinding.value || binding.value) return false
  if (selectedSlot.value) return true
  const selection = slotSelection.value
  return !schedule.value.length && !!selection && shiftBookable(selection.slot, now.value)
})
const name = ref('')
const sex = ref('')
const age = ref('')
const symptoms = ref('')
const patients = ref([])
const patientsLoading = ref(false)
const patientsError = ref(false)
const patientId = ref('')
const choosingPatient = ref(false)
const savePatient = ref(false)
const submitting = ref(false)
const pendingBooking = ref(null)
const createdNo = ref('')
const formLocked = computed(() => submitting.value || !!pendingBooking.value || !!createdNo.value)
let openedDetail = false
let openingEditor = false
let visibilityRevision = 0

onLoad(async options => {
  if (!await canOpenBooking('form', options)) return
  bookingParams.value = options
  selectedDate.value = options.date || ''
  refresh()
  refreshPatients()
  try {
    const user = await readProfile()
    if (!phone.value && user?.mobile) phone.value = user.mobile
  } catch (error) {
    notify(error.message || '暂时无法读取本人资料')
  }
})

onShow(() => {
  if (openedDetail) {
    if (getCurrentPages().length > 1) uni.navigateBack()
    else uni.redirectTo({ url: '/pages/ucenter/appointments' })
    return
  }
  if (!bookingParams.value || fromDemo.value) return
  checkAppAccess()
  if (needsBinding.value) return recheckPhoneRequirement()
  checkingBinding.value = false
})

function suspendBookingChecks() {
  visibilityRevision++
  if (!fromDemo.value && needsBinding.value) checkingBinding.value = true
}
onHide(suspendBookingChecks)
onUnload(suspendBookingChecks)

watch([schedule, now], ([days]) => {
  if (!days.length) picking.value = false
  else if (!fromDemo.value && slotSelection.value && !selectedSlot.value && !checkingBinding.value && !formLocked.value) {
    if (needsBinding.value) reselectSlot()
    else slotSelection.value = null
  }
})

watch(signedIn, active => {
  if (active) return
  choosingPatient.value = false
  patients.value = []
  patientsError.value = false
  patientId.value = name.value = sex.value = age.value = phone.value = symptoms.value = ''
  savePatient.value = false
  pendingBooking.value = null
  createdNo.value = ''
}, { flush: 'sync' })

async function refreshPatients() {
  if (patientsLoading.value || !signedIn.value) return
  patientsLoading.value = true
  patientsError.value = false
  try {
    patients.value = await loadPatients()
    if (patientId.value && !patients.value.some(patient => patient.id === patientId.value)) patientId.value = ''
  } catch {
    patientsError.value = signedIn.value
  } finally {
    patientsLoading.value = false
  }
}

function fillPatient(patient) {
  name.value = patient?.name || ''
  sex.value = patient?.sex || ''
  age.value = patient ? String(patient.age) : ''
}

async function choosePatient(id = '') {
  choosingPatient.value = false
  if (id && id === patientId.value) return
  if (symptoms.value.trim()) {
    const result = await uni.showModal({
      title: '切换就诊人', content: '切换就诊人将清空已填写的症状描述。',
      cancelText: '保留原文', confirmText: '切换',
    })
    if (!result.confirm || !signedIn.value) return
  }
  const patient = patients.value.find(item => item.id === id)
  if (id && !patient) return notify('未找到该就诊人，请重新选择')
  patientId.value = id
  fillPatient(patient)
  symptoms.value = ''
  savePatient.value = false
}

function openPatientPicker() {
  if (formLocked.value) return
  uni.hideKeyboard()
  choosingPatient.value = true
}

async function editPatient(id) {
  if (openingEditor) return
  openingEditor = true
  try {
    await uni.navigateTo({
      url: '/pages/booking/patient_edit?id=' + encodeURIComponent(id),
      events: { patientChanged },
    })
  } catch {
    notify('暂时无法打开编辑页，请重试')
  } finally {
    openingEditor = false
  }
}

function patientChanged({ id, patient }) {
  if (!signedIn.value) return
  patients.value = patient
    ? patients.value.map(item => item.id === id ? patient : item)
    : patients.value.filter(item => item.id !== id)
  if (patientId.value === id) {
    // Removing the profile leaves the current draft available as manual entry.
    if (patient) fillPatient(patient)
    else patientId.value = ''
  }
  refreshPatients()
}

async function selectTime() {
  if (formLocked.value) return
  uni.hideKeyboard()
  if (fromDemo.value) {
    refresh()
  } else {
    if (!await canUseApp() || !doctor.value) return
    if (!departments.value.length) return notify(NO_BOOKABLE_DEPARTMENT)
    if (!schedule.value.length) return notify('排班暂不可用，请重试')
    refreshClock()
    if (!selectedSlot.value) slotSelection.value = null
  }
  if (schedule.value.length) picking.value = true
}

function setTime(selection) {
  refreshClock()
  selectedDate.value = selection.date
  slotSelection.value = selection
  needsBinding.value = false
  checkingBinding.value = false
  picking.value = false
}

function notify(title) {
  uni.showToast({ title, icon: 'none' })
}

function reselectSlot(message = '时段已不可约，请重新选择') {
  slotSelection.value = null
  needsBinding.value = false
  notify(message)
}

function selectionData({ doctorId, date, slot }) {
  return {
    doctor_id: doctorId, date, time_slot: slot.time_slot, mode: slot.timed ? 'slot' : 'shift',
    start_time: slot.start_time, end_time: slot.end_time,
  }
}

async function checkSelection(selection) {
  const result = await requestForUser('appointment_check', { data: selectionData(selection) })
  if ([result?.bookable, result?.booking_phone_required, result?.booking_symptoms_required].some(value => typeof value !== 'boolean')) {
    throw new Error('排班暂不可用，请重试')
  }
  return result
}

async function recheckPhoneRequirement() {
  checkingBinding.value = true
  const revision = visibilityRevision
  const selection = slotSelection.value
  try {
    if (!selection) return reselectSlot()
    const result = await checkSelection(selection)
    if (revision !== visibilityRevision || selection !== slotSelection.value) return
    if (!result.bookable || (schedule.value.length && !selectedSlot.value)) return reselectSlot()
    needsBinding.value = result.booking_phone_required
  } catch (error) {
    if (revision !== visibilityRevision || selection !== slotSelection.value) return
    needsBinding.value = false
    notify(error.message || '暂时无法核对预约，请重试')
  } finally {
    if (revision === visibilityRevision) checkingBinding.value = false
  }
}

function phoneDenied() {
  if (!canAuthorizePhone.value) return
  needsBinding.value = false
  notify('已取消授权，预约内容已保留')
}

async function verifyPhone(result) {
  if (!canAuthorizePhone.value) return
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
  if (submitting.value || checkingBinding.value || binding.value || openedDetail) return
  const selection = slotSelection.value
  const revision = visibilityRevision
  if (!createdNo.value && !pendingBooking.value) {
    refreshClock()
    if (!fromDemo.value && !departments.value.length) return notify(NO_BOOKABLE_DEPARTMENT)
    if (!selection) return notify('请选择时段')
    const message = !patientId.value && patientValidationMessage({ name: name.value, sex: sex.value, age: age.value })
    if (message) return notify(message)
  }
  submitting.value = true
  uni.hideKeyboard()
  try {
    if (!createdNo.value) {
      if (fromDemo.value) {
        await submitDemoBooking()
      } else {
        if (!pendingBooking.value) {
          if (!department.value) return notify('请选择科室')
          pendingBooking.value = {
            ...selectionData(selection), department_id: department.value.id, idempotency_key: newBookingKey(),
            patient_id: patientId.value || undefined, patient_name: name.value,
            patient_gender: ['未知', '男', '女'].indexOf(sex.value), patient_age: Number(age.value),
            patient_mobile: phone.value, remark: symptoms.value, save_patient: savePatient.value,
          }
        }
        await submitRealBooking(revision)
      }
    }
    if (!createdNo.value || revision !== visibilityRevision || !signedIn.value) return
    await uni.navigateTo({ url: '/pages/ucenter/appointment_detail?created=1&no=' + createdNo.value })
    openedDetail = true
  } catch (error) {
    if (revision === visibilityRevision && signedIn.value) await handleBookingError(error)
  } finally {
    submitting.value = false
  }
}

async function submitDemoBooking() {
  if (!demoMode) return notify('体验预约请使用体验登录')
  const user = await readProfile()
  if (!user) return notify('请先登录')
  refreshClock()
  if (!selectedSlot.value) return notify('请选择时段')
  if (bookingSymptomsRequired.value && !symptoms.value.trim()) return notify('请填写症状描述')
  const contact = phone.value.trim().replace(/[ -]/g, '')
  if (!/^\+?\d{6,15}$/.test(contact)) return notify('请输入有效的本次联系电话')
  const record = createAppointment(user.user_no, newAppointmentNo(), {
    doctorId: doctor.value.id, date: date.value, slot: selectedSlot.value.label, phone: contact,
    name: name.value, sex: sex.value, age: age.value, symptoms: symptoms.value,
    patientId: patientId.value, savePatient: savePatient.value,
  })
  createdNo.value = record.no
}

async function submitRealBooking(revision) {
  const draft = pendingBooking.value
  let result
  try {
    result = await submitAppointment(draft)
  } catch (error) {
    if (error.code !== 'same_name') throw error
    pendingBooking.value = null
    if (revision !== visibilityRevision || !signedIn.value) return
    const { confirm } = await uni.showModal({
      title: '同名就诊人', content: error.message, cancelText: '返回核对', confirmText: '继续预约',
    })
    if (!confirm || revision !== visibilityRevision || !signedIn.value) return
    pendingBooking.value = { ...draft, confirm_same_name: true }
    result = await submitAppointment(pendingBooking.value)
  }
  if (revision !== visibilityRevision || !signedIn.value) return
  pendingBooking.value = null
  if (result.outcome === 'already_booked') {
    const { confirm } = await uni.showModal({
      title: '已预约这个时段', content: '可查看原单', cancelText: '返回表单', confirmText: '查看原单',
    })
    if (confirm && revision === visibilityRevision && signedIn.value) {
      await uni.navigateTo({ url: '/pages/ucenter/appointment_detail?no=' + result.order_no })
    }
  } else {
    createdNo.value = result.order_no
    refreshAppConfiguration({ fresh: true })
  }
}

async function handleBookingError(error) {
  if ([400, 422].includes(error.statusCode)) pendingBooking.value = null
  if (error.code === 'phone_required') {
    needsBinding.value = true
    await nextTick()
    uni.pageScrollTo({ selector: '#phone-binding', duration: 180 })
  } else if (['selection_changed', 'slot_closed', 'slot_full'].includes(error.code)) {
    reselectSlot(error.message)
    refreshAppConfiguration()
  } else {
    if (error.code === 'fee_changed' || error.code === 'department_unavailable') refreshAppConfiguration()
    if (error.code === 'patient_not_found') refreshPatients()
    notify(createdNo.value ? '已创建预约，点击查看详情' : error.message || '提交失败，请重试')
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
        <view class="row date-row" aria-role="button" @tap="selectTime">
          <view>预约日期<text class="required">*</text></view><text>{{ date || '请选择日期' }}</text>
        </view>
        <view class="row time-row" aria-role="button" @tap="selectTime">
          <view>预约时段<text class="required">*</text></view><text>{{ slotText }}</text>
        </view>
        <view class="row phone-row"><view>本次联系电话<text class="required">*</text></view>
          <input v-model="phone" :disabled="formLocked" aria-label="本次联系电话" :maxlength="21" placeholder="请输入本次联系电话" />
        </view>
        <picker v-if="chooseDepartment" :range="departments" range-key="name" :value="departmentIndex" :disabled="formLocked" @change="setDepartment">
          <view class="row department-row" aria-role="button">
            <view>科室<text class="required">*</text></view><text>{{ departmentName || '请选择科室' }} ›</text>
          </view>
        </picker>
        <view v-else-if="departmentName || !fromDemo" class="row">
          <text>科室</text><text>{{ departmentName || '暂无可预约科室' }}</text>
        </view>
        <view v-if="hospitalAddress" class="row address-row">
          <text class="address-label">就诊地址</text>
          <text class="address-value" :class="{ 'address-link': hospitalCanNavigate }" :aria-role="hospitalCanNavigate ? 'button' : undefined"
            @tap="hospitalCanNavigate && openHospitalLocation(() => !!hospitalAddress)">{{ hospitalAddress }}</text>
        </view>
        <view v-if="feeText" class="row"><text>挂号费</text><text>{{ feeText }}</text></view>
      </view>
      <view v-if="bookingNotice" class="panel booking-notice">
        <view class="panel-title">预约须知</view>
        <view class="booking-notice-text">{{ bookingNotice }}</view>
      </view>
      <view class="panel patient">
        <view class="panel-title">添加就诊人信息
          <text v-if="patients.length || patientsError" class="choose-patient" aria-role="button" :aria-disabled="formLocked" @tap="openPatientPicker">选择就诊人 ›</text>
        </view>
        <PatientFields v-model:name="name" v-model:sex="sex" v-model:age="age" :locked="!!patientId" :disabled="formLocked" />
        <checkbox-group v-if="!patientId" class="save-patient" @change="savePatient = !!$event.detail.value.length">
          <label><checkbox value="save" :checked="savePatient" :disabled="formLocked" color="#5ba7e5" />保存为常用就诊人</label>
        </checkbox-group>
        <view class="symptoms">症状描述<text v-if="bookingSymptomsRequired" class="required">*</text>
          <view v-if="picking || choosingPatient" class="description">{{ symptoms }}</view>
          <textarea v-else v-model="symptoms" :disabled="formLocked" class="description" placeholder="请输入" aria-label="症状描述" :maxlength="-1" />
        </view>
      </view>
      <view v-if="demoMode" class="demo-note">本地模拟预约，请使用虚构就诊资料</view>
      <button v-if="checkingBinding || binding" class="submit" hover-class="none" disabled>{{ binding ? '验证中…' : '正在核对预约…' }}</button>
      <view v-else-if="canAuthorizePhone" id="phone-binding">
        <view class="binding-note">医院要求先验证账号手机号。本次联系电话可填写家属号码。</view>
        <custom-phone-authorization label="验证账号手机号" @authorized="verifyPhone" @denied="phoneDenied" @failed="canAuthorizePhone && notify('手机号授权失败，请重试')">
          <view class="submit bind-button">验证账号手机号</view>
        </custom-phone-authorization>
      </view>
      <button v-else class="submit" hover-class="none" :disabled="submitting" @tap="confirmBooking">{{ submitting ? '确认中…' : createdNo ? '查看预约详情' : pendingBooking ? '重试确认预约' : '确定预约' }}</button>
      <SlotPicker v-if="picking && schedule.length" :schedule="schedule" :doctor-id="doctor.id" :date="date"
        :demo="fromDemo" :selected-slot="selectedSlot" :now="now"
        @confirm="setTime" @cancel="picking = false" />
      <PatientPicker v-if="choosingPatient" :patients="patients" :selected="patientId"
        :loading="patientsLoading" :load-error="patientsError"
        @confirm="choosePatient" @add="choosePatient()" @edit="editPatient"
        @retry="refreshPatients" @cancel="choosingPatient = false" />
    </view>
    <view v-else class="unavailable">暂无该医生信息</view>
  </view>
</template>

<style scoped lang="scss">
@use './form';
@use './form-fields';

.service-panel { padding-bottom: 0; }
.service-panel .row:last-child { border-bottom-color: transparent; }
.address-row { padding-block: 16rpx; }
.address-label { flex: none; }
.address-value { min-width: 0; margin-left: 20rpx; text-align: right; white-space: pre-wrap; overflow-wrap: anywhere; }
.address-link { color: #2877b7; }
.booking-notice { margin-top: 20rpx; }
.booking-notice-text { color: #555; line-height: 1.55; white-space: pre-wrap; overflow-wrap: anywhere; }
.patient { margin-top: 34rpx; }
.choose-patient { margin-left: auto; padding: 10rpx 8rpx; color: #438ac4; font-size: 25rpx; }
.save-patient { margin-top: 18rpx; color: #666; font-size: 24rpx; }
.save-patient checkbox { transform: scale(.8); }
.demo-note { margin: 24rpx 0 10rpx; color: #777; font-size: 22rpx; text-align: center; }
.binding-note { margin: 16rpx 0; color: #536777; font-size: 25rpx; }
.bind-button { text-align: center; }
.symptoms { padding-top: 34rpx; }
.description { display: block; box-sizing: border-box; width: 100%; height: 150rpx; margin-top: 10rpx; padding: 26rpx; border: 2rpx solid #ddd; border-radius: 8rpx; font-size: 28rpx; }
.unavailable { padding: 40rpx; text-align: center; color: #888; }
</style>
