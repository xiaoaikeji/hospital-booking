import { listPatients, updatePatient, removePatient } from '@/mock/appointments.js'
import { demoMode, profile, requestForUser } from '@/store/session.js'

const sexes = ['未知', '男', '女']

function responsePatient(patient, id = patient?.id) {
  if (!patient || typeof id !== 'string' || patient.id !== id || typeof patient.name !== 'string'
      || !Number.isInteger(patient.gender) || !sexes[patient.gender] || !Number.isInteger(patient.age)) {
    throw new Error('未取得就诊人资料，请重试')
  }
  return { id, name: patient.name, sex: sexes[patient.gender], age: patient.age }
}

function patientPath(id) {
  return 'patients/' + encodeURIComponent(id)
}

export async function loadPatients() {
  if (demoMode) return listPatients(profile.value?.user_no)
  const result = await requestForUser('patients', { expectedStatus: 200 })
  if (!Array.isArray(result?.patients)) throw new Error('未取得常用就诊人名单，请重试')
  return result.patients.map(patient => responsePatient(patient))
}

export async function loadPatient(id) {
  if (demoMode) {
    const patient = listPatients(profile.value?.user_no).find(item => item.id === id)
    if (!patient) throw new Error('未找到该就诊人')
    return patient
  }
  return responsePatient(await requestForUser(patientPath(id), { expectedStatus: 200 }), id)
}

export async function savePatientProfile(id, { name, sex, age }) {
  if (demoMode) return updatePatient(profile.value?.user_no, id, { name, sex, age })
  const patient = { name, gender: sexes.indexOf(sex), age: Number(age) }
  const result = await requestForUser(patientPath(id), { method: 'PATCH', data: { patient }, expectedStatus: 200 })
  return responsePatient(result, id)
}

export async function removePatientProfile(id) {
  if (demoMode) return removePatient(profile.value?.user_no, id)
  await requestForUser(patientPath(id), { method: 'DELETE', expectedStatus: 204 })
}

export function patientValidationMessage({ name, sex, age }) {
  if (!name.trim()) return '请输入就诊人姓名'
  if (name.trim().length > 100) return '就诊人姓名最多100个字符'
  if (!['男', '女'].includes(sex)) return '请选择性别'
  if (!/^\d{1,3}$/.test(age) || Number(age) < 1 || Number(age) > 200) return '请输入1至200之间的年龄'
  return ''
}
