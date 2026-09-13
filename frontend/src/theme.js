import { WindowSetDarkTheme, WindowSetLightTheme, WindowSetSystemDefaultTheme } from '../wailsjs/runtime/runtime';

let nativeTheme;

export function applyTheme(theme, syncNative = false) {
  if (syncNative && nativeTheme !== theme) {
    nativeTheme = theme;
    if (theme === 'dark') WindowSetDarkTheme();
    else if (theme === 'light') WindowSetLightTheme();
    else WindowSetSystemDefaultTheme();
  }
  const effective = theme === 'light' || theme === 'dark'
    ? theme
    : (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  document.documentElement.dataset.mode = effective;
}
