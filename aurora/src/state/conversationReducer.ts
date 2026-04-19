import type { ConversationAction, ConversationState, Message } from './types';

export const initialState: ConversationState = {
  phase: 'idle',
  messages: [],
  partialUserText: '',
  partialAssistantText: '',
  crisisDetected: false,
};

function makeId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function appendMessage(state: ConversationState, msg: Message): Message[] {
  return [...state.messages, msg];
}

export function conversationReducer(
  state: ConversationState,
  action: ConversationAction
): ConversationState {
  switch (action.type) {
    case 'RESET':
      return initialState;

    case 'START_LISTENING':
      return {
        ...state,
        phase: 'listening',
        partialUserText: '',
        errorMessage: undefined,
      };

    case 'CANCEL_LISTENING':
      return { ...state, phase: 'idle' };

    case 'USER_TURN': {
      const userMsg: Message = {
        id: makeId(),
        role: 'user',
        content: action.userText,
        audioUri: action.audioUri,
        createdAt: Date.now(),
      };
      return {
        ...state,
        phase: 'thinking',
        messages: appendMessage(state, userMsg),
        partialUserText: '',
        partialAssistantText: '',
      };
    }

    case 'ASSISTANT_PARTIAL':
      return {
        ...state,
        partialAssistantText: state.partialAssistantText + action.chunk,
      };

    case 'ASSISTANT_DONE': {
      const text = state.partialAssistantText.trim();
      if (!text) return { ...state, phase: 'idle' };
      const assistantMsg: Message = {
        id: makeId(),
        role: 'assistant',
        content: text,
        createdAt: Date.now(),
      };
      return {
        ...state,
        phase: 'speaking',
        messages: appendMessage(state, assistantMsg),
        partialAssistantText: '',
      };
    }

    case 'SPEAK_START':
      return { ...state, phase: 'speaking' };

    case 'SPEAK_END':
      return { ...state, phase: 'idle' };

    case 'ERROR':
      return { ...state, phase: 'error', errorMessage: action.message };

    case 'CRISIS_FLAG':
      return { ...state, crisisDetected: true };

    default:
      return state;
  }
}
