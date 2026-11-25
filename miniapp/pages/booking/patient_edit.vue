<script setup>
import { getCurrentInstance, ref, watch } from 'vue'
import { onLoad } from '@dcloudio/uni-app'
import { signedIn } from '@/store/session.js'
import { loadPatient, patientValidationMessage, removePatientProfile, savePatientProfile } from './patient-profiles.js'
import PatientFields from './components/patient_fields.vue'

const page = getCurrentInstance().proxy
const name = ref('')
const sex = ref('')
const age = ref('')
const loading = ref(true)
const loadError = ref('')
const working = ref(false)
let patientId

onLoad(options => {
  patientId = options.id
  refreshPatient()
})

watch(signedIn, active => {
  if (active) return
  name.value = sex.value = age.value = ''
  loadError.value = '请先登录'
}, { flush: 'sync' })

async function refreshPatient() {
  loading.value = true
  loadError.value = ''
  try {
    if (!patientId) throw new Error('未找到该就诊人')
    const patient = await loadPatient(patientId)
    name.value = patient.name
    sex.value = patient.sex
    age.value = String(patient.age)
  } catch (error) {
    loadError.value = error.message || '暂时无法读取就诊人资料'
  } finally {
    loading.value = false
  }
}

async function finish(patient) {
  page.getOpenerEventChannel()?.emit('patientChanged', { id: patientId, patient })
  if (getCurrentPages().length > 1) await uni.navigateBack()
  else await uni.switchTab({ url: '/pages/index/index' })
}

function notify(title) {
  uni.showToast({ title, icon: 'none' })
}

async function save() {
  if (working.value) return
  const attributes = { name: name.value, sex: sex.value, age: age.value }
  const message = patientValidationMessage(attributes)
  if (message) return notify(message)

  working.value = true
  try {
    const patient = await savePatientProfile(patientId, attributes)
    await finish(patient)
  } catch (error) {
    notify(error.message || '就诊人资料暂时无法保存')
  } finally {
    working.value = false
  }
}

async function remove() {
  if (working.value) return
  working.value = true
  try {
    const result = await uni.showModal({
      title: '移除就诊人',
      content: '从常用名单移除这位就诊人？',
      cancelText: '取消',
      confirmText: '移除',
      confirmColor: '#b44e4e',
    })
    if (!result.confirm) return
    await removePatientProfile(patientId)
    await finish(null)
  } catch (error) {
    notify(error.message || '就诊人暂时无法移除')
  } finally {
    working.value = false
  }
}
</script>

<template>
  <view class="booking-form">
    <view class="header"><custom-page-header title="编辑就诊人" back /></view>
    <view v-if="loading" class="unavailable">正在读取就诊人资料…</view>
    <view v-else-if="loadError" class="unavailable">
      <text>{{ loadError }}</text>
      <button v-if="signedIn" class="submit retry" hover-class="none" @tap="refreshPatient">重试</button>
    </view>
    <view v-else class="form-content">
      <view class="panel">
        <view class="panel-title">就诊人信息</view>
        <PatientFields v-model:name="name" v-model:sex="sex" v-model:age="age" :locked="working" />
      </view>
      <button class="submit save" hover-class="none" :disabled="working" @tap="save">保存</button>
      <button class="remove" hover-class="none" :disabled="working" @tap="remove">移除就诊人</button>
    </view>
  </view>
</template>

<style scoped lang="scss">
@use './form';

.unavailable { padding: 40rpx; text-align: center; color: #888; }
.save, .retry { margin-top: 24rpx; }
.remove { margin: 24rpx 0 0; border-radius: 16rpx; background: #fff; color: #b44e4e; font-size: 26rpx; line-height: 64rpx; }
.remove::after { border: 0; }
</style>
