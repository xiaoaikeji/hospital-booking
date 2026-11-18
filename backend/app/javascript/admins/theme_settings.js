// The server resolves Booking defaults and account overrides before first paint.
;(function () {
  const script = document.currentScript
  const nativeDefaults = JSON.parse(script.dataset.nativeDefaults)
  let values = JSON.parse(script.dataset.values)
  const colorScheme = window.matchMedia('(prefers-color-scheme: dark)')
  const schemes = {
    auto: { theme: 'auto', navbar_theme: 'default' },
    light: { theme: 'light', navbar_theme: 'default' },
    dark: { theme: 'dark', navbar_theme: 'default' },
    'dark-nav': { theme: 'light', navbar_theme: 'dark' },
    colored: { theme: 'light', navbar_theme: 'primary' },
  }

  function updateFavicon() {
    const brand = document.querySelector('[data-booking-brand-mark]')
    if (!brand) return // The first theme application runs before the body is parsed.

    const favicon = document.querySelector('[data-theme-favicon]')
    const icon = brand.cloneNode(true)
    const colors = getComputedStyle(document.documentElement)
    for (const property of ['--tblr-primary', '--tblr-primary-fg']) {
      icon.style.setProperty(property, colors.getPropertyValue(property))
    }
    const svg = new XMLSerializer().serializeToString(icon)
    const href = 'data:image/svg+xml,' + encodeURIComponent(svg)
    if (favicon.getAttribute('href') !== href) favicon.setAttribute('href', href)
  }

  function applyTheme() {
    for (const [key, value] of Object.entries(values)) {
      const applied = key === 'theme' && value === 'auto' ? (colorScheme.matches ? 'dark' : 'light') : value
      if (applied === nativeDefaults[key]) {
        document.documentElement.removeAttribute('data-bs-' + key.replaceAll('_', '-'))
      } else {
        document.documentElement.setAttribute('data-bs-' + key.replaceAll('_', '-'), applied)
      }
    }
    updateFavicon()
  }

  applyTheme()
  colorScheme.addEventListener('change', applyTheme)
  // Old Tabler keys have no account owner. Leave unrelated browser data alone.
  try {
    for (const key of Object.keys(nativeDefaults)) window.localStorage.removeItem('tabler-' + key.replaceAll('_', '-'))
  } catch { /* Storage may be unavailable in private browsing. */ }
  window.addEventListener('pageshow', (event) => {
    if (event.persisted) window.location.reload()
  })

  document.addEventListener('DOMContentLoaded', function () {
    const form = document.getElementById('theme-settings')
    const controls = form.querySelector('fieldset')
    const reset = form.querySelector('#reset-theme-settings')
    const status = form.querySelector('[data-theme-status]')
    const defaults = JSON.parse(form.dataset.defaults)
    let overrides = JSON.parse(form.dataset.overrides)
    let revision = form.dataset.revision
    const inheritButtons = new Map()

    function fieldsFor(name) {
      return name === 'scheme' ? ['theme', 'navbar_theme'] : [name.replaceAll('-', '_')]
    }

    if (form.dataset.url) {
      for (const group of form.querySelectorAll('[data-theme-setting]')) {
        const keys = fieldsFor(group.dataset.themeSetting)
        const button = document.createElement('button')
        button.type = 'button'
        button.className = 'btn btn-link btn-sm ms-2'
        button.textContent = '跟随默认'
        button.addEventListener('click', () => save(Object.fromEntries(keys.map(key => [key, null]))))
        group.querySelector('.form-label').append(button)
        inheritButtons.set(button, keys)
      }
    }

    function render() {
      applyTheme()
      for (const radio of form.querySelectorAll('input[type="radio"]')) {
        radio.checked = radio.name === 'scheme'
          ? Object.entries(schemes[radio.value]).every(([key, value]) => values[key] === value)
          : values[radio.name.replaceAll('-', '_')] === radio.value
      }
      for (const [button, keys] of inheritButtons) button.hidden = !keys.some(key => key in overrides)
      const position = values.navbar_position
      form.querySelector('[data-theme-setting="sidebar"]').hidden = position === 'horizontal'
      form.querySelector('[data-theme-setting="navbar"]').hidden = position === 'vertical'
      document.querySelector('[data-admin-horizontal-brand]')?.classList.toggle('d-none', position !== 'horizontal')
      window.dispatchEvent(new Event('resize'))
    }

    async function save(changes, clearAll = false) {
      const previous = values
      values = clearAll ? { ...defaults } : { ...values }
      for (const [key, value] of Object.entries(changes)) values[key] = value ?? defaults[key]
      render()
      if (!form.dataset.url) return

      controls.disabled = reset.disabled = true
      status.textContent = '正在保存…'
      try {
        const response = await fetch(form.dataset.url, {
          method: clearAll ? 'DELETE' : 'PATCH',
          headers: {
            'Content-Type': 'application/json', 'Accept': 'application/json',
            'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
          },
          body: JSON.stringify({ appearance: changes, revision }),
        })
        if (!response.headers.get('Content-Type')?.includes('application/json')) throw new Error()
        const result = await response.json()
        if (!response.ok) throw new Error(result.error)
        values = result.values
        overrides = result.overrides
        revision = result.revision
        status.textContent = clearAll ? '已恢复全后台默认外观' : '个人外观已保存'
      } catch (error) {
        values = previous
        status.textContent = error.message && !(error instanceof TypeError) ? error.message : '保存失败，请刷新页面后重试'
      } finally {
        controls.disabled = reset.disabled = false
        render()
      }
    }

    form.addEventListener('submit', (event) => event.preventDefault())
    form.addEventListener('change', (event) => {
      const { name, value } = event.target
      const selection = name === 'scheme' ? schemes[value] : { [name.replaceAll('-', '_')]: value }
      const changes = Object.fromEntries(Object.entries(selection).filter(([key, choice]) => values[key] !== choice))
      if (Object.keys(changes).length) save(changes)
    })
    reset.addEventListener('click', () => save({}, true))
    render()
  })
})()
