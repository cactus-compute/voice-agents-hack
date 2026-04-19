import React from "react";
import { View, Text, SafeAreaView } from "react-native";
import { theme } from "../theme";

export function DocumentScanScreen() {
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: theme.colors.background }}>
      <View style={{ flex: 1, justifyContent: "center", alignItems: "center" }}>
        <Text style={theme.typography.h2}>Document Scanner</Text>
        <Text style={{ ...theme.typography.body, color: theme.colors.textMuted, marginTop: theme.spacing.sm }}>
          Shell — Agent 4 will fill this in
        </Text>
      </View>
    </SafeAreaView>
  );
}
