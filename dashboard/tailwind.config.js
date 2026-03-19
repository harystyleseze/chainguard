/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          DEFAULT: '#FF007A',
          dark: '#cc0062',
        },
      },
    },
  },
  plugins: [],
}
