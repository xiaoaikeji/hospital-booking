import { findDoctor } from './doctors.js'
import { getBookingSchedule, getBookingSlots } from './booking-schedule.js'

const STORAGE_KEY = 'booking-demo-appointments-v1'
const PAYMENT_DELAY = 1200
const REVIEW_DELAY = 3500
const REFUND_DELAY = 6500

// 本地模拟渠道的回执。修改为 false 可验证支付失败或退号审核未通过。
export const demoResults = { paymentApproved: true, refundApproved: true }

function readLedger() {
  const ledger = uni.getStorageSync(STORAGE_KEY) || { appointments: [], patients: [] }
  // Earlier tourist previews keyed the one demo account by its fixture phone number.
  for (const row of [...ledger.appointments, ...ledger.patients]) {
    if (row.owner === '10000000000') row.owner = 'demo'
  }
  return ledger
}

export function listAppointments(owner) {
  if (!owner) return []
  return readLedger().appointments.filter(item => item.owner === owner)
}

export function listPatients(owner) {
  if (!owner) return []
  return readLedger().patients.filter(item => item.owner === owner)
}

export function updatePatient(owner, id, attributes) {
  const ledger = readLedger()
  const patient = owner && ledger.patients.find(item => item.owner === owner && item.id === id)
  if (!patient) throw new Error('未找到该就诊人')
  Object.assign(patient, patientInformation(attributes))
  uni.setStorageSync(STORAGE_KEY, ledger)
  return patient
}

export function removePatient(owner, id) {
  const ledger = readLedger()
  const index = owner ? ledger.patients.findIndex(item => item.owner === owner && item.id === id) : -1
  if (index < 0) throw new Error('未找到该就诊人')
  ledger.patients.splice(index, 1)
  uni.setStorageSync(STORAGE_KEY, ledger)
}

export function newAppointmentNo() {
  const rows = readLedger().appointments
  const beijing = new Date(Date.now() + 8 * 3600000)
  const prefix = beijing.toISOString().slice(0, 19).replace(/\D/g, '')
  let number
  do {
    number = prefix + String(Math.floor(Math.random() * 1000000)).padStart(6, '0')
  } while (rows.some(row => row.no === number))
  return number
}

function slotBoundaries(date, slot) {
  const [year, month, day] = date.split('-').map(Number)
  return slot.split('–').map(time => {
    const [hour, minute] = time.split(':').map(Number)
    return new Date(year, month - 1, day, hour, minute).getTime()
  })
}

// 进度取自本次模拟回执及时间，离开页面或重启后仍可继续查询。
export function bookingStatus(item, now = Date.now()) {
  if (item.canceled) return 'canceled'
  if (item.refundAt != null) {
    const elapsed = now - item.refundAt
    if (elapsed < REVIEW_DELAY) return 'reviewing'
    if (item.refundApproved) return elapsed < REFUND_DELAY ? 'refunding' : 'refunded'
    if (now < item.endsAt) return 'rejected'
  }
  if (item.fee > 0) {
    if (item.paymentAt != null && now - item.paymentAt < PAYMENT_DELAY) return 'confirming'
    if (!item.paymentApproved) {
      if (now >= item.startsAt) return 'closed'
      return item.paymentAt != null ? 'paymentFailed' : 'unpaid'
    }
  }
  return now >= item.endsAt ? 'completed' : 'confirmed'
}

export const statusLabels = {
  unpaid: '待支付', paymentFailed: '支付失败', confirming: '支付确认中',
  confirmed: '待就诊', canceled: '已取消', closed: '已关闭', completed: '已完成',
  reviewing: '退号审核中', refunding: '退款处理中', refunded: '已退款', rejected: '退号未通过',
}

// 页面只在可操作时限或模拟回执到达时刷新。
export function nextChangeAt(item, now) {
  const times = [item.startsAt, item.endsAt]
  if (item.paymentAt != null) times.push(item.paymentAt + PAYMENT_DELAY)
  if (item.refundAt != null) times.push(item.refundAt + REVIEW_DELAY, item.refundAt + REFUND_DELAY)
  return Math.min(...times.filter(time => time > now))
}

function availableSlots(day, doctorId, records, now) {
  const held = {}
  for (const row of records) {
    if (row.doctorId !== doctorId || row.date !== day?.date) continue
    if (['canceled', 'closed', 'refunded', 'refunding'].includes(bookingStatus(row, now.getTime()))) continue
    held[row.slot] = (held[row.slot] || 0) + 1
  }
  return getBookingSlots(day, doctorId, now).map(slot => ({
    ...slot, remaining: Math.max(0, slot.remaining - (held[slot.label] || 0)),
  }))
}

export function getAvailableSlots(day, doctorId) {
  return availableSlots(day, doctorId, readLedger().appointments, new Date())
}

function patientInformation({ name, sex, age }) {
  if (!name.trim() || !['男', '女'].includes(sex) || !Number.isInteger(+age) || +age < 1 || +age > 200) {
    throw new Error('请核对就诊人信息')
  }
  return { name: name.trim(), sex, age: +age }
}

export function createAppointment(owner, no, draft) {
  if (!owner) throw new Error('请先授权登录')
  const ledger = readLedger()
  const existing = ledger.appointments.find(item => item.no === no)
  if (existing) {
    if (existing.owner !== owner) throw new Error('预约编号冲突，请重新进入表单')
    return existing
  }
  const doctor = findDoctor(draft.doctorId)
  if (!doctor) throw new Error('暂无该医生信息')
  const now = new Date()
  const day = getBookingSchedule(now).find(item => item.date === draft.date)
  const available = availableSlots(day, doctor.id, ledger.appointments, now)
  if (!available.some(item => item.label === draft.slot && item.remaining > 0)) {
    throw new Error('该时段已约满，请重新选择')
  }
  const saved = ledger.patients.find(item => item.id === draft.patientId && item.owner === owner)
  if (draft.patientId && !saved) throw new Error('请重新选择就诊人')
  const patient = patientInformation(saved || draft)
  if (!draft.phone) throw new Error('请输入本次联系电话')
  const [startsAt, endsAt] = slotBoundaries(day.date, draft.slot)
  const record = {
    no, owner, doctorId: doctor.id, doctor: doctor.name, department: doctor.department, fee: doctor.fee,
    date: day.date, slot: draft.slot, startsAt, endsAt, createdAt: now.getTime(),
    phone: draft.phone, patient, symptoms: draft.symptoms,
  }
  if (!saved && draft.savePatient) ledger.patients.push({ ...patient, id: no, owner })
  ledger.appointments.unshift(record)
  // 常用就诊人、预约和占号共用同一次同步写入。
  uni.setStorageSync(STORAGE_KEY, ledger)
  return record
}

export function allowedActions(item, now = Date.now()) {
  const status = bookingStatus(item, now)
  if (['unpaid', 'paymentFailed'].includes(status)) return ['cancel', 'pay']
  if (status === 'confirmed' && now < item.startsAt) return [item.fee ? 'refund' : 'cancel']
  return []
}

export function updateAppointment(owner, no, action) {
  const ledger = readLedger()
  const item = owner && ledger.appointments.find(row => row.no === no && row.owner === owner)
  if (!item) throw new Error('暂无该预约记录')
  const now = Date.now()
  if (!allowedActions(item, now).includes(action)) throw new Error('预约状态已更新，请查看详情')
  if (action === 'pay') {
    item.paymentAt = now
    item.paymentApproved = demoResults.paymentApproved
  } else if (action === 'refund') {
    item.refundAt = now
    item.refundApproved = demoResults.refundApproved
  } else {
    item.canceled = true
  }
  uni.setStorageSync(STORAGE_KEY, ledger)
}
