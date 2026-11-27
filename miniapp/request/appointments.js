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
  return records.map(record => {
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
    }
  })
}

function validNumber(value) {
  return typeof value === 'string' && /^[0-9]{20}$/.test(value)
}
