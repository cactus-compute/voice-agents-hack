import { useState } from 'react';
import { SCENARIOS } from './scenarios';
import { TracePanel } from './components/TracePanel';
import { RouteBadge } from './components/RouteBadge';
import './App.css';

function App() {
  const [activeId, setActiveId] = useState(SCENARIOS[0].id);
  const active = SCENARIOS.find((s) => s.id === activeId)!;

  return (
    <div className="app">
      {/* Header */}
      <header className="app-header">
        <div className="app-header-left">
          <span className="app-logo">🛡️</span>
          <div>
            <div className="app-title">Masker</div>
            <div className="app-subtitle">Real-time privacy layer for local voice agents</div>
          </div>
        </div>
        <div className="app-header-right">
          <span className="app-pipeline">
            Mic → Cactus STT → <strong>Masker</strong> → Gemma → Cactus TTS → Speaker
          </span>
        </div>
      </header>

      <div className="app-body">
        {/* Scenario selector sidebar */}
        <aside className="sidebar">
          <div className="sidebar-label">Demo Scenarios</div>
          {SCENARIOS.map((s) => (
            <button
              key={s.id}
              className={`scenario-btn ${s.id === activeId ? 'active' : ''}`}
              onClick={() => setActiveId(s.id)}
            >
              <div className="scenario-btn-label">{s.label}</div>
              <RouteBadge route={s.route} />
            </button>
          ))}

          <div className="sidebar-divider" />

          <div className="sidebar-label">Pipeline</div>
          <div className="flow-diagram">
            <div className="flow-step">🎙️ User speaks</div>
            <div className="flow-arrow">↓</div>
            <div className="flow-step">📝 Cactus STT</div>
            <div className="flow-arrow">↓</div>
            <div className="flow-step highlight">🛡️ Masker detects + routes</div>
            <div className="flow-arrow">↓</div>
            <div className="flow-step">🤖 Gemma (if routed)</div>
            <div className="flow-arrow">↓</div>
            <div className="flow-step">🔊 Cactus TTS</div>
          </div>
        </aside>

        {/* Main trace panel */}
        <main className="main-panel">
          <div className="main-panel-header">
            <h2 className="main-panel-title">{active.label}</h2>
          </div>
          <TracePanel trace={active} />
        </main>
      </div>

      <footer className="app-footer">
        Masker · Hackathon prototype · HIPAA-first programmable compliance for Cactus + Gemma voice agents
      </footer>
    </div>
  );
}

export default App;
