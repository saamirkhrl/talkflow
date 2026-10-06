using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Talkflow;

/// <summary>
/// The user's own API keys, in Windows Credential Manager (generic
/// credentials, encrypted with DPAPI under the user's account), never in a
/// file (APIKeys.swift keeps them in the Keychain).
/// </summary>
static class ApiKeys
{
    public enum Provider { OpenAI, Anthropic }

    static readonly object Gate = new();
    static readonly Dictionary<Provider, string> Cache = new();

    public static string Name(Provider provider) => provider == Provider.OpenAI ? "OpenAI" : "Anthropic";

    static string Target(Provider provider) => provider == Provider.OpenAI ? "talkflow/openai" : "talkflow/anthropic";

    public static string? Get(Provider provider)
    {
        lock (Gate)
        {
            if (Cache.TryGetValue(provider, out var cached)) return cached.Length == 0 ? null : cached;
            string value = "";
            if (Native.CredRead(Target(provider), Native.CRED_TYPE_GENERIC, 0, out var pointer))
            {
                try
                {
                    var credential = Marshal.PtrToStructure<Native.CREDENTIAL>(pointer);
                    if (credential.CredentialBlobSize > 0)
                    {
                        var bytes = new byte[credential.CredentialBlobSize];
                        Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
                        value = Encoding.UTF8.GetString(bytes);
                    }
                }
                finally
                {
                    Native.CredFree(pointer);
                }
            }
            Cache[provider] = value;
            return value.Length == 0 ? null : value;
        }
    }

    public static bool Has(Provider provider) => Get(provider) is not null;

    public static bool Save(Provider provider, string value)
    {
        var trimmed = value.Trim();
        var bytes = Encoding.UTF8.GetBytes(trimmed);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Native.CREDENTIAL
            {
                Type = Native.CRED_TYPE_GENERIC,
                TargetName = Target(provider),
                CredentialBlob = blob,
                CredentialBlobSize = bytes.Length,
                Persist = Native.CRED_PERSIST_LOCAL_MACHINE,
                UserName = "talkflow",
                Comment = "API key added in talkflow's Settings",
            };
            lock (Gate)
            {
                bool ok = Native.CredWrite(ref credential, 0);
                if (ok) Cache[provider] = trimmed;
                else Log.Write($"could not save the {Name(provider)} key (error {Marshal.GetLastWin32Error()})");
                return ok;
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public static void Remove(Provider provider)
    {
        lock (Gate)
        {
            Native.CredDelete(Target(provider), Native.CRED_TYPE_GENERIC, 0);
            Cache[provider] = "";
        }
    }
}
