export interface TranscriptEntry {
  id: string;
  rawText: string;
  editedText: string;
  wasEdited: boolean;
  timestamp: number;
  fieldsExtracted: string[];
}
