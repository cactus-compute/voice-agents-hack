export type Role = 'system' | 'user' | 'assistant';

export interface Message {
  id: string;
  role: Role;
  content: string;
  audioUri?: string;
  createdAt: number;
}

export type SessionPhase =
  | 'idle'
  | 'listening'
  | 'thinking'
  | 'speaking'
  | 'error';

export interface ConversationState {
  phase: SessionPhase;
  messages: Message[];
  partialUserText: string;
  partialAssistantText: string;
  errorMessage?: string;
  crisisDetected: boolean;
}

export type ConversationAction =
  | { type: 'RESET' }
  | { type: 'START_LISTENING' }
  | { type: 'CANCEL_LISTENING' }
  | { type: 'USER_TURN'; userText: string; audioUri?: string }
  | { type: 'ASSISTANT_PARTIAL'; chunk: string }
  | { type: 'ASSISTANT_DONE' }
  | { type: 'SPEAK_START' }
  | { type: 'SPEAK_END' }
  | { type: 'ERROR'; message: string }
  | { type: 'CRISIS_FLAG' };
