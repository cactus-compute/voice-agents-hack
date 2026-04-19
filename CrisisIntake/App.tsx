import React from "react";
import { StatusBar } from "react-native";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { NavigationContainer } from "@react-navigation/native";
import { createStackNavigator } from "@react-navigation/stack";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { IntakeSessionScreen } from "./src/screens/IntakeSessionScreen";
import { DocumentScanScreen } from "./src/screens/DocumentScanScreen";
import { ResourcePlanScreen } from "./src/screens/ResourcePlanScreen";

export type RootStackParamList = {
  IntakeSession: undefined;
  DocumentScan: undefined;
  ResourcePlan: undefined;
};

const Stack = createStackNavigator<RootStackParamList>();

function App() {
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <StatusBar barStyle="dark-content" />
        <NavigationContainer>
          <Stack.Navigator
            initialRouteName="IntakeSession"
            screenOptions={{ headerShown: false }}
          >
            <Stack.Screen name="IntakeSession" component={IntakeSessionScreen} />
            <Stack.Screen name="DocumentScan" component={DocumentScanScreen} />
            <Stack.Screen name="ResourcePlan" component={ResourcePlanScreen} />
          </Stack.Navigator>
        </NavigationContainer>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

export default App;
