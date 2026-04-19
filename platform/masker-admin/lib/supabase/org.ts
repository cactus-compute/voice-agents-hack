import { createClient } from "./server";

/** Returns the org for the currently authed user, or null. */
export async function getAuthedOrg() {
  const supabase = createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: org } = await supabase
    .from("orgs")
    .select("*")
    .eq("owner_id", user.id)
    .maybeSingle();

  return org;
}
