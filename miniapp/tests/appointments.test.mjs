import assert from 'node:assert/strict'
import { beforeEach, test } from 'node:test'
import {
  allowedActions, bookingStatus, createAppointment, demoResults, getAvailableSlots,
  listAppointments, listPatients, newAppointmentNo, nextChangeAt, updateAppointment,
} from '../mock/appointments.js'
import { getBookingSchedule } from '../mock/booking-schedule.js'

beforeEach(() => {
  const storage = new Map()
  globalThis.uni = {
    getStorageSync: key => structuredClone(storage.get(key)),
    setStorageSync: (key, value) => storage.set(key, structuredClone(value)),
  }
  demoResults.paymentApproved = true
  demoResults.refundApproved = true
})

function form(doctorId) {
  const day = getBookingSchedule()[1]
  const slot = getAvailableSlots(day, doctorId).find(item => item.remaining >= 2)
  return { doctorId, date: day.date, slot: slot.label, phone: '10000000000',
    name: '测试甲', sex: '女', age: '32', symptoms: '', savePatient: true }
}

test('retrying a successful submission keeps one appointment, one saved patient and one held seat', () => {
  const draft = form(1)
  const day = getBookingSchedule()[1]
  const seats = () => getAvailableSlots(day, 1).find(item => item.label === draft.slot).remaining
  const before = seats()
  const number = newAppointmentNo()
  assert.match(number, /^\d{20}$/)
  createAppointment('A', number, draft)
  createAppointment('A', number, draft)
  assert.equal(listAppointments('A').length, 1)
  assert.equal(listPatients('A').length, 1)
  assert.equal(seats(), before - 1)
  assert.equal(bookingStatus(listAppointments('A')[0]), 'confirmed')
  updateAppointment('A', number, 'cancel')
  assert.equal(seats(), before)
})

test('last seat is rechecked before saving; another account cannot read, reuse or cancel a booking', () => {
  const draft = form(2)
  const day = getBookingSchedule()[1]
  const seats = getAvailableSlots(day, 2).find(item => item.label === draft.slot).remaining
  const first = createAppointment('A', newAppointmentNo(), draft)
  const patientId = listPatients('A')[0].id
  assert.deepEqual(listPatients('B'), [])
  assert.deepEqual(listAppointments(null), [])
  assert.throws(() => createAppointment('B', newAppointmentNo(), { ...draft, patientId }), /就诊人/)
  assert.throws(() => updateAppointment('B', first.no, 'cancel'), /暂无/)
  for (let count = 1; count < seats; count++) {
    createAppointment('A', newAppointmentNo(), { ...draft, patientId })
  }
  assert.throws(() => createAppointment('B', newAppointmentNo(), draft), /已约满/)
  assert.deepEqual(listPatients('B'), [])
  assert.equal(listPatients('A').length, 1)
})

test('payment and refund survive reopening, reject repeats and keep the original appointment number', t => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-11-20T08:00:00+08:00').getTime() })
  const { no } = createAppointment('A', newAppointmentNo(), form(2))
  const current = () => listAppointments('A')[0]
  updateAppointment('A', no, 'pay')
  assert.equal(bookingStatus(current()), 'confirming')
  assert.throws(() => updateAppointment('A', no, 'pay'), /状态/)
  t.mock.timers.tick(2000)
  assert.equal(bookingStatus(current()), 'confirmed')
  updateAppointment('A', no, 'refund')
  assert.equal(bookingStatus(current()), 'reviewing')
  assert.deepEqual(allowedActions(current()), [])
  t.mock.timers.tick(nextChangeAt(current(), Date.now()) - Date.now())
  assert.equal(bookingStatus(current()), 'refunding')
  t.mock.timers.tick(nextChangeAt(current(), Date.now()) - Date.now())
  assert.equal(bookingStatus(current()), 'refunded')
  assert.throws(() => updateAppointment('A', no, 'refund'), /状态/)
})

test('failed payment can be retried, and a rejected refund keeps the original paid booking', t => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-11-20T08:00:00+08:00').getTime() })
  const { no } = createAppointment('A', newAppointmentNo(), { ...form(2), savePatient: false })
  assert.deepEqual(listPatients('A'), [])
  const current = () => listAppointments('A')[0]
  demoResults.paymentApproved = false
  updateAppointment('A', no, 'pay')
  t.mock.timers.tick(2000)
  assert.equal(bookingStatus(current()), 'paymentFailed')
  demoResults.paymentApproved = true
  updateAppointment('A', no, 'pay')
  t.mock.timers.tick(2000)
  demoResults.refundApproved = false
  updateAppointment('A', no, 'refund')
  t.mock.timers.tick(7000)
  assert.equal(bookingStatus(current()), 'rejected')
  assert.equal(current().paymentApproved, true)
  assert.equal(listAppointments('A').length, 1)
})
