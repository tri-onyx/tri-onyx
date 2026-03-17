# Web Dashboard

The gateway serves a web dashboard at `http://localhost:4000` with several views for monitoring and managing your agents.

## Views

### Frontend (`/`)

Agent overview and control panel. Start and stop agents, send prompts, and view agent status at a glance.

### Graph (`/graph`)

Real-time agent topology with taint and sensitivity propagation visualization. See how information flows between agents and where policy violations would occur.

### Matrix (`/matrix`)

Classification matrix showing taint, sensitivity, and capability levels for all agents. Quickly identify which agents are high-risk based on the lethal trifecta.

### Log Viewer (`/logs`)

Session log browser with structured event display. Browse agent sessions, view tool calls, file access events, message routing, and policy violations.
