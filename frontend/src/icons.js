import {
  ArrowLeft, ArrowRight, ArrowUpRight, Cast, Check, ChevronDown, CircleAlert,
  CircleHelp, Copy, Info, LoaderCircle, Maximize2, Minus, Monitor, MonitorPlay,
  Play, RefreshCw, Settings2, ShieldCheck, Smartphone, Square, Volume2,
  VolumeX, Wifi, X,
} from 'lucide';
import { escAttr } from './format.js';

const icons = {
  'arrow-left': ArrowLeft, 'arrow-right': ArrowRight, 'arrow-up-right': ArrowUpRight,
  cast: Cast, check: Check, chevron: ChevronDown, alert: CircleAlert,
  help: CircleHelp, copy: Copy, info: Info, loader: LoaderCircle, expand: Maximize2,
  minus: Minus, monitor: Monitor, 'monitor-play': MonitorPlay,
  play: Play, refresh: RefreshCw, settings: Settings2, shield: ShieldCheck,
  phone: Smartphone, square: Square, volume: Volume2, muted: VolumeX, wifi: Wifi, close: X,
};

export function icon(name, className = '') {
  const nodes = icons[name];
  if (!nodes) throw new Error(`Unknown icon: ${name}`);
  return `<svg class="icon ${className}" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${nodes.map(([tag, attrs]) =>
    `<${tag} ${Object.entries(attrs).map(([key, value]) => `${key}="${escAttr(value)}"`).join(' ')} />`).join('')}</svg>`;
}
