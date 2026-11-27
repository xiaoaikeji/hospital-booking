import { requestForUser } from '@/store/session.js'

export function newBookingKey() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID()
  const randomPart = () => Math.floor(Math.random() * 36 ** 8).toString(36).padStart(8, '0')
  return Date.now().toString(36) + '-' + randomPart() + randomPart()
}

export async function submitAppointment(appointment) {
  const result = await requestForUser('appointments', { method: 'POST', data: { appointment } })
  if (!validNumber(result?.order_no) || !['created', 'replayed', 'already_booked'].includes(result.outcome)) {
    throw new Error('暂未收到预约结果，请重新确认')
  }
  return result
}

export async function loadAppointments(orderNo) {
  const path = orderNo ? 'appointments/' + encodeURIComponent(orderNo) : 'appointments'
  const result = await requestForUser(path, { expectedStatus: 200 })
  const records = orderNo ? [result] : result?.appointments
  if (!Array.isArray(records)) throw new Error('暂时无法读取预约记录')
  return records.map(record => appointmentRecord(record, orderNo))
}

export async function startAppointmentPayment(orderNo) {
  const result = await requestForUser(appointmentAction(orderNo, 'payment'), { method: 'POST' })
  if (!validNumber(result?.payment_no) || !result?.payment_params?.paySign) {
    throw new Error('暂时无法调起支付，请重试')
  }
  return result
}

export async function checkAppointmentPayment(orderNo) {
  return updateAppointment(orderNo, 'check_payment')
}

export async function cancelPendingAppointment(orderNo) {
  return updateAppointment(orderNo, 'cancel')
}

export async function requestAppointmentReturn(orderNo, key) {
  return updateAppointment(orderNo, 'return_booking', { refund: { idempotency_key: key } })
}

async function updateAppointment(orderNo, action, data) {
  const result = await requestForUser(appointmentAction(orderNo, action), { method: 'POST', data })
  return appointmentRecord(result, orderNo)
}

function appointmentAction(orderNo, action) {
  if (!validNumber(orderNo)) throw new Error('暂无该预约记录')
  return 'appointments/' + orderNo + '/' + action
}

function appointmentRecord(record, orderNo) {
  if (!validNumber(record?.order_no) || (orderNo && orderNo !== record.order_no) || typeof record.status_label !== 'string') {
    throw new Error('暂时无法读取预约记录')
  }
  return {
    no: record.order_no,
    status: record.status,
    statusLabel: record.status_label,
    doctor: record.doctor_name,
    department: record.department_name,
    date: record.appointment_date,
    slot: record.slot_label,
    fee: record.fee,
    patient: { name: record.patient_name, sex: record.patient_sex, age: record.patient_age },
    phone: record.patient_mobile,
    address: record.hospital_snapshot?.address,
    symptoms: record.remark,
    paymentStatus: record.payment_status,
    paymentExpiresAt: Date.parse(record.payment_expires_at),
    serverOffset: Number.isFinite(record.server_time) ? record.server_time - Date.now() : 0,
    paymentClosing: record.payment_closing,
    paymentChecking: record.payment_checking,
    paymentStarted: record.payment_started,
    canPay: record.can_pay,
    originalPaymentApp: record.original_payment_app,
    canReturn: record.can_return,
    canCancel: record.can_cancel,
    paid: record.paid,
    refundStatus: record.refund_status,
    refundLabel: record.refund_label,
    refunds: record.refunds || [],
  }
}

function validNumber(value) {
  return typeof value === 'string' && /^[0-9]{20}$/.test(value)
}
