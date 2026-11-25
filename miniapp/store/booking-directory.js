import { computed } from 'vue'
import { bookingDirectory } from './app-configuration.js'
import { demoMode } from './session.js'
import { doctors as demoDoctors, findDoctor as findDemoDoctor } from '@/mock/doctors.js'
import { API_ORIGIN } from '@/request/http.js'

const demoDepartments = [{ id: '', name: '耳鼻喉科', depth: 0 }]
export const directoryDemoMode = demoMode || !API_ORIGIN
export const bookingDepartments = computed(() => directoryDemoMode ? demoDepartments : bookingDirectory.value.departments)

const directoryDoctors = computed(() => {
  const names = new Map(bookingDirectory.value.departments.map(department => [department.id, department.name]))
  return bookingDirectory.value.doctors.map(doctor => ({
    ...doctor,
    title: doctor.main_title,
    portrait: doctor.image_url || '/static/ucenter/wechat-avatar.svg',
    credentials: doctor.department_ids.map(id => names.get(id)).filter(Boolean),
    biography: doctor.introduction,
    introduction: doctor.good_in,
  }))
})

export const bookingDoctors = computed(() => directoryDemoMode ? demoDoctors : directoryDoctors.value)
export const homepageDoctors = computed(() => directoryDemoMode ? demoDoctors : directoryDoctors.value.filter(doctor => doctor.display_on_homepage))

export function findBookingDoctor(id, fromDemo) {
  return fromDemo ? findDemoDoctor(id) : directoryDoctors.value.find(doctor => doctor.id === String(id))
}
