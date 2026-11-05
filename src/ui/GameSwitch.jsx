// The transition before Blink restarts into or out of game mode: the screen goes dark and
// a ring folds into a dot (on) or opens back up (off).
import { useStore } from '../lib/store.js';

export default function GameSwitch() {
  const on = useStore((s) => s.gameSwitch);
  if (on === undefined || on === null) return null;
  return (
    <div className={'game-fx gs ' + (on ? 'on' : 'off')} aria-hidden="true">
      <span className="gs-ring" />
      <div className="gs-text">
        <b>{on ? 'Игровой режим' : 'Обычный режим'}</b>
        <span>Blink перезапускается</span>
      </div>
    </div>
  );
}
