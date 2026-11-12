// The page's light or dark colours (store `theme`): the colour tokens in
// index.html, switched by data-theme on the root. The spatial view and the
// scatter canvas stay dark in both. Charts drawn on a canvas (Vega, the
// density bins) cannot use the CSS variables, so they take the token values
// when built and are rebuilt when the theme changes (panels/dock.ts
// refreshCharts()).
export type Theme = 'dark' | 'light';
export const THEMES: Theme[] = ['dark', 'light'];

export function applyTheme(theme: Theme): void {
  if (theme === 'light') document.documentElement.dataset.theme = 'light';
  else delete document.documentElement.dataset.theme;
}

// A token's value on the page, e.g. token('fg-2') is '#9ca3af' when dark
export const token = (name: string): string =>
  getComputedStyle(document.documentElement).getPropertyValue(`--${name}`).trim();

export const tokenRGB = (name: string): [number, number, number] => {
  const h = token(name);
  return [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
};

// Vega axis colours; titles are each chart's own
export const chartAxis = () => ({
  labelColor: token('fg-2'), domainColor: token('bg-3'), tickColor: token('bg-3'), gridColor: token('bg-2'),
});
