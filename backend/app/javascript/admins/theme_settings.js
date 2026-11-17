// Adapted from Desktop/tabler-1.7.1/dashboard/index.html, theme-settings page script.
;(function () {
  const themeDefaults = {
    theme: 'auto',
    'theme-base': 'neutral',
    'theme-font': 'sans-serif',
    'theme-primary': 'blue',
    'theme-radius': '1',
    layout: 'default',
    navbar: 'default',
    'navbar-position': 'horizontal',
    'navbar-style': 'default',
    'navbar-theme': 'default',
    'offcanvas-style': 'default',
    sidebar: 'default',
  }
  // Reset to Booking's existing full-width, combined navigation layout.
  const pageDefaults = { ...themeDefaults, layout: 'fluid', 'navbar-position': 'combined' }
  const themePresets = {
    scheme: {
      auto: { theme: 'auto', 'navbar-theme': 'default' },
      light: { theme: 'light', 'navbar-theme': 'default' },
      dark: { theme: 'dark', 'navbar-theme': 'default' },
      'dark-nav': { theme: 'light', 'navbar-theme': 'dark' },
      colored: { theme: 'light', 'navbar-theme': 'primary' },
    },
  }

  document.addEventListener('DOMContentLoaded', function () {
    const url = new URL(window.location)
    const form = document.getElementById('theme-settings')
    const resetButton = document.getElementById('reset-theme-settings')
    if (!form || !resetButton) return
    form.addEventListener('submit', function (event) { event.preventDefault() })

    // Tabler's native defaults are represented by the absence of an attribute.
    const applyValue = function (key, value) {
      let applied = value
      if (key === 'theme' && value === 'auto') {
        applied = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
      }
      if (applied !== themeDefaults[key]) {
        document.documentElement.setAttribute('data-bs-' + key, applied)
      } else {
        document.documentElement.removeAttribute('data-bs-' + key)
      }
    }

    const currentValue = function (key) {
      const stored = window.localStorage.getItem('tabler-' + key)
      const rendered = key === 'theme' ? null : document.documentElement.getAttribute('data-bs-' + key)
      return stored || rendered || themeDefaults[key]
    }

    const toggleNavigationSettings = function () {
      const position = currentValue('navbar-position')
      form.querySelector('[data-theme-setting="sidebar"]').hidden = position === 'horizontal'
      form.querySelector('[data-theme-setting="navbar"]').hidden = position === 'vertical'
      document.querySelector('[data-admin-horizontal-brand]')?.classList.toggle('d-none', position !== 'horizontal')
    }

    const setValue = function (key, value) {
      applyValue(key, value)
      window.localStorage.setItem('tabler-' + key, value)
      url.searchParams.set(key, value)
    }

    const checkItems = function () {
      for (const key in themeDefaults) {
        const value = currentValue(key)
        form.querySelectorAll('[name="' + key + '"]').forEach(function (radio) {
          radio.checked = radio.value === value
        })
      }
      for (const name in themePresets) {
        form.querySelectorAll('[name="' + name + '"]').forEach(function (radio) {
          const values = themePresets[name][radio.value]
          radio.checked = Object.keys(values).every(function (key) {
            return currentValue(key) === values[key]
          })
        })
      }
      toggleNavigationSettings()
    }

    form.addEventListener('change', function (event) {
      const { name, value } = event.target
      if (name in themePresets) {
        const values = themePresets[name][value]
        for (const key in values) setValue(key, values[key])
      } else if (name in themeDefaults) {
        setValue(name, value)
      }
      checkItems()
      window.dispatchEvent(new Event('resize'))
      window.history.replaceState({}, '', url)
    })

    resetButton.addEventListener('click', function () {
      for (const key in themeDefaults) {
        applyValue(key, pageDefaults[key])
        window.localStorage.removeItem('tabler-' + key)
        url.searchParams.delete(key)
      }
      checkItems()
      window.dispatchEvent(new Event('resize'))
      window.history.replaceState({}, '', url)
    })

    // The early vendor script only accepts integer URL values; keep its native
    // half-step radius options working when a settings URL is opened directly.
    const radius = url.searchParams.get('theme-radius')
    if (radius === '0.5' || radius === '1.5') setValue('theme-radius', radius)

    checkItems()
  })
})()
