import React, { useState } from "react";
import { View, Text, SafeAreaView, TextInput, TouchableOpacity, ScrollView, ActivityIndicator } from "react-native";
import { theme } from "../theme";
import { extractionEngine } from "../services/extraction";
import { useAppStore } from "../store/useAppStore";

export function IntakeSessionScreen() {
  const [testTranscript, setTestTranscript] = useState("My name is Bob, I am 45 years old, and I have lived in an apartment for 2 months.");
  const [loading, setLoading] = useState(false);
  const [extracting, setExtracting] = useState(false);
  const [lastDelta, setLastDelta] = useState<any>(null);

  const intake = useAppStore(s => s.intake);
  const modelsLoaded = useAppStore(s => s.modelsLoaded);
  const setModelsLoaded = useAppStore(s => s.setModelsLoaded);
  const mergeFields = useAppStore(s => s.mergeFields);

  const handleLoadModel = async () => {
    setLoading(true);
    try {
      await extractionEngine.loadModels();
      setModelsLoaded(true);
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  };

  const handleTestExtraction = async () => {
    console.log("[UI] 'Run Extraction' button pressed!");
    setExtracting(true);
    try {
      const delta = await extractionEngine.extractFromTranscript(testTranscript, intake);
      console.log("[UI] Extraction complete, delta received:", delta);
      if (delta) {
        setLastDelta(delta);
        mergeFields(delta, "voice");
      } else {
        console.warn("[UI] No delta received or extraction returned null.");
      }
    } catch (e) {
      console.error("[UI] Error during handleTestExtraction:", e);
    } finally {
      setExtracting(false);
    }
  };

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: theme.colors.background }}>
      <ScrollView contentContainerStyle={{ padding: theme.spacing.lg }}>
        <Text style={theme.typography.h1}>Intake Session</Text>
        
        {/* Verification / Test Dashboard */}
        <View style={{ 
          marginTop: theme.spacing.xl, 
          padding: theme.spacing.md, 
          backgroundColor: theme.colors.surface, 
          borderRadius: theme.radii.lg,
          borderWidth: 1,
          borderColor: theme.colors.fieldEmptyBorder
        }}>
          <Text style={theme.typography.sectionHeader}>Extraction Debug Tool</Text>
          
          <View style={{ marginTop: theme.spacing.md }}>
            <Text style={theme.typography.caption}>Status: {modelsLoaded ? "🟢 Model Ready" : "🔴 Model Not Loaded"}</Text>
            
            {!modelsLoaded && (
              <TouchableOpacity 
                onPress={handleLoadModel}
                disabled={loading}
                style={{ 
                  backgroundColor: theme.colors.accent, 
                  padding: theme.spacing.md, 
                  borderRadius: theme.radii.md,
                  marginTop: theme.spacing.sm,
                  alignItems: 'center'
                }}
              >
                {loading ? <ActivityIndicator color="white" /> : <Text style={{ color: 'white', fontWeight: '600' }}>Load Gemma 4 Engine</Text>}
              </TouchableOpacity>
            )}
          </View>

          <View style={{ marginTop: theme.spacing.lg }}>
            <Text style={theme.typography.body}>Sample Transcript:</Text>
            <TextInput
              multiline
              value={testTranscript}
              onChangeText={setTestTranscript}
              style={{
                backgroundColor: theme.colors.background,
                padding: theme.spacing.md,
                borderRadius: theme.radii.md,
                marginTop: theme.spacing.sm,
                borderWidth: 1,
                borderColor: theme.colors.fieldEmptyBorder,
                minHeight: 80
              }}
            />

            <TouchableOpacity 
              onPress={handleTestExtraction}
              disabled={!modelsLoaded || extracting}
              style={{ 
                backgroundColor: modelsLoaded ? theme.colors.fieldInferredAccent : theme.colors.textMuted, 
                padding: theme.spacing.md, 
                borderRadius: theme.radii.md,
                marginTop: theme.spacing.md,
                alignItems: 'center'
              }}
            >
              {extracting ? <ActivityIndicator color="white" /> : <Text style={{ color: 'white', fontWeight: '600' }}>Run Extraction</Text>}
            </TouchableOpacity>
          </View>

          {lastDelta && (
            <View style={{ marginTop: theme.spacing.lg, padding: theme.spacing.sm, backgroundColor: '#f1f1f1', borderRadius: theme.radii.sm }}>
              <Text style={theme.typography.caption}>Last Delta Extracted:</Text>
              <Text style={{ fontSize: 10, fontFamily: 'Courier' }}>{JSON.stringify(lastDelta, null, 2)}</Text>
            </View>
          )}
        </View>

        <Text style={{ ...theme.typography.caption, marginTop: theme.spacing.xxl, textAlign: 'center' }}>
          Form Preview: {Object.values(intake).filter(f => f.status !== 'empty').length} fields extracted
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}
