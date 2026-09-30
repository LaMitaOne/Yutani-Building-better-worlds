unit GameNetworkingSockets;

{$ALIGN 8}

interface

uses
  System.SysUtils, Winapi.Windows;

{==============================================================================*
 *  GameNetworkingSockets Delphi Wrapper v0.1 - Dynamic Flat C API Bindings
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *  License MIT
 *  Description:
 *    This unit provides a fully dynamic wrapper for Valve's open-source
 *    GameNetworkingSockets library. It loads the DLL at runtime and binds
 *    the flat C API functions. It automatically handles C++ name mangling
 *    (like MSVC's @4 decorators) to prevent "procedure not found" errors.
 *
 *  Architecture:
 *    - No static linking. The DLL is loaded via LoadLibrary.
 *    - If a function is missing in the DLL (e.g. SDR Relay functions in
 *      standalone builds), it is set to nil and safely skipped by the host.
 *    - Implements the v009 interface for ISteamNetworkingSockets and
 *      ISteamNetworkingUtils.
 *=============================================================================}

type
  // Primitive Types
  HSteamNetConnection = UInt32;
  HSteamListenSocket = UInt32;
  HSteamNetPollGroup = UInt32;
  SteamNetworkingPOPID = UInt32;
  SteamNetworkingMicroseconds = Int64;
  uint64_steamid = UInt64;
  EResult = Int32;

  SteamNetworkingErrMsg = array[0..1023] of AnsiChar;

  // Opaque Interface Pointers
  ISteamNetworkingSockets = Pointer;
  ISteamNetworkingUtils = Pointer;
  ISteamNetworkingMessages = Pointer;

  // Enums (Defined as Int32 for alignment)
  ESteamNetworkingAvailability = Int32;
  ESteamNetworkingConnectionState = Int32;
  ESteamNetworkingSocketsDebugOutputType = Int32;
  ESteamNetworkingConfigScope = Int32;
  ESteamNetworkingConfigDataType = Int32;
  ESteamNetworkingConfigValue = Int32;

  // C-Structs
  PSteamNetworkingIPAddr = ^SteamNetworkingIPAddr;
  SteamNetworkingIPAddr = packed record
    case Integer of
      0: (m_ipv6: array[0..15] of Byte; m_port: Word);
      1: (m_ipv4_8zeros: UInt64; m_ipv4_0000: Word; m_ipv4_ffff: Word; m_ipv4_ip: array[0..3] of Byte; m_ipv4_port: Word);
  end;

  PSteamNetworkingIdentity = ^SteamNetworkingIdentity;
  SteamNetworkingIdentity = packed record
    m_eType: Int32;
    m_cbSize: Int32;
    case Integer of
      0: (m_steamID64: UInt64);
      1: (m_szGenericString: array[0..31] of AnsiChar);
      2: (m_genericBytes: array[0..31] of Byte);
      3: (m_ip: SteamNetworkingIPAddr);
  end;

  PSteamNetworkingConfigValue_t = ^SteamNetworkingConfigValue_t;
  SteamNetworkingConfigValue_t = packed record
    m_eValue: Int32;
    m_eDataType: Int32;
    case Integer of
      0: (m_int32: Int32);
      1: (m_int64: Int64);
      2: (m_float: Single);
      3: (m_string: PAnsiChar);
      4: (m_ptr: Pointer);
  end;

  PSteamNetConnectionInfo_t = ^SteamNetConnectionInfo_t;
  SteamNetConnectionInfo_t = packed record
    m_identityRemote: SteamNetworkingIdentity;
    m_nUserData: Int64;
    m_hListenSocket: HSteamListenSocket;
    m_addrRemote: SteamNetworkingIPAddr;
    m__pad1: Word;
    m_idPOPRemote: SteamNetworkingPOPID;
    m_idPOPRelay: SteamNetworkingPOPID;
    m_eState: ESteamNetworkingConnectionState;
    m_eEndReason: Int32;
    m_szEndDebug: array[0..127] of AnsiChar;
    m_szConnectionDescription: array[0..127] of AnsiChar;
    m_nFlags: Int32;
    reserved: array[0..62] of Cardinal;
  end;

  PSteamNetConnectionRealTimeStatus_t = ^SteamNetConnectionRealTimeStatus_t;
  SteamNetConnectionRealTimeStatus_t = packed record
    m_eState: ESteamNetworkingConnectionState;
    m_nPing: Int32;
    m_flConnectionQualityLocal: Single;
    m_flConnectionQualityRemote: Single;
    m_flOutPacketsPerSec: Single;
    m_flOutBytesPerSec: Single;
    m_flInPacketsPerSec: Single;
    m_flInBytesPerSec: Single;
    m_nSendRateBytesPerSecond: Int32;
    m_cbPendingUnreliable: Int32;
    m_cbPendingReliable: Int32;
    m_cbSentUnackedReliable: Int32;
    m_usecQueueTime: SteamNetworkingMicroseconds;
    m_usecMaxJitter: Int32;
    reserved: array[0..14] of Cardinal;
  end;

  PSteamNetworkingMessage_t = ^SteamNetworkingMessage_t;
  PPSteamNetworkingMessage_t = ^PSteamNetworkingMessage_t;
  SteamNetworkingMessage_t = packed record
    m_pData: Pointer;
    m_cbSize: Int32;
    m_conn: HSteamNetConnection;
    m_identityPeer: SteamNetworkingIdentity;
    m_nConnUserData: Int64;
    m_usecTimeReceived: SteamNetworkingMicroseconds;
    m_nMessageNumber: Int64;
    m_pfnFreeData: Pointer;
    m_pfnRelease: Pointer;
    m_nChannel: Int32;
    m_nFlags: Int32;
    m_nUserData: Int64;
    m_idxLane: Word;
    _pad1__: Word;
  end;

  // --- Function Pointer Types (Typedefs) ---
  TGameNetworkingSockets_Init = function(const pLocalAddress: PSteamNetworkingIPAddr; pErrMsg: PAnsiChar): Boolean; cdecl;
  TGameNetworkingSockets_Kill = procedure; cdecl;

  TSteamAPI_SteamNetworkingSockets_v009 = function: ISteamNetworkingSockets; cdecl;
  TCreateListenSocketIP = function(self: ISteamNetworkingSockets; localAddress: PSteamNetworkingIPAddr; nOptions: Integer; pOptions: PSteamNetworkingConfigValue_t): HSteamListenSocket; cdecl;
  TConnectByIPAddress = function(self: ISteamNetworkingSockets; address: PSteamNetworkingIPAddr; nOptions: Integer; pOptions: PSteamNetworkingConfigValue_t): HSteamNetConnection; cdecl;
  TAcceptConnection = function(self: ISteamNetworkingSockets; hConn: HSteamNetConnection): EResult; cdecl;
  TCloseConnection = function(self: ISteamNetworkingSockets; hPeer: HSteamNetConnection; nReason: Int32; pszDebug: PAnsiChar; bEnableLinger: Boolean): Boolean; cdecl;
  TSendMessageToConnection = function(self: ISteamNetworkingSockets; hConn: HSteamNetConnection; pData: Pointer; cbData: UInt32; nSendFlags: Int32; pOutMessageNumber: PInt64): EResult; cdecl;
  TReceiveMessagesOnConnection = function(self: ISteamNetworkingSockets; hConn: HSteamNetConnection; ppOutMessages: PPSteamNetworkingMessage_t; nMaxMessages: Int32): Int32; cdecl;
  TGetConnectionInfo = function(self: ISteamNetworkingSockets; hConn: HSteamNetConnection; pInfo: PSteamNetConnectionInfo_t): Boolean; cdecl;
  TGetConnectionRealTimeStatus = function(self: ISteamNetworkingSockets; hConn: HSteamNetConnection; pStats: PSteamNetConnectionRealTimeStatus_t; nLanes: Int32; pLanes: Pointer): EResult; cdecl;
  TRunCallbacks = procedure(self: ISteamNetworkingSockets); cdecl;
  TCreatePollGroup = function(self: ISteamNetworkingSockets): HSteamNetPollGroup; cdecl;
  TDestroyPollGroup = function(self: ISteamNetworkingSockets; hPollGroup: HSteamNetPollGroup): Boolean; cdecl;
  TSetConnectionPollGroup = function(self: ISteamNetworkingSockets; hConn: HSteamNetConnection; hPollGroup: HSteamNetPollGroup): Boolean; cdecl;
  TReceiveMessagesOnPollGroup = function(self: ISteamNetworkingSockets; hPollGroup: HSteamNetPollGroup; ppOutMessages: PPSteamNetworkingMessage_t; nMaxMessages: Int32): Int32; cdecl;

  TSteamAPI_SteamNetworkingUtils_v003 = function: ISteamNetworkingUtils; cdecl;
  TInitRelayNetworkAccess = procedure(self: ISteamNetworkingUtils); cdecl;
  TGetRelayNetworkStatus = function(self: ISteamNetworkingUtils; pDetails: Pointer): ESteamNetworkingAvailability; cdecl;
  TSetGlobalConfigValueInt32 = function(self: ISteamNetworkingUtils; eValue: ESteamNetworkingConfigValue; val: Int32): Boolean; cdecl;
  TGetLocalTimestamp = function(self: ISteamNetworkingUtils): SteamNetworkingMicroseconds; cdecl;
  TSetDebugOutputFunction = procedure(self: ISteamNetworkingUtils; eDetailLevel: ESteamNetworkingSocketsDebugOutputType; pfnFunc: Pointer); cdecl;

  TIPAddr_Clear = procedure(self: PSteamNetworkingIPAddr); cdecl;
  TIPAddr_SetIPv4 = procedure(self: PSteamNetworkingIPAddr; nIP: Cardinal; nPort: Word); cdecl;
  TIPAddr_ToString = procedure(self: PSteamNetworkingIPAddr; buf: PAnsiChar; cbBuf: NativeUInt; bWithPort: Boolean); cdecl;

  TIdentity_Clear = procedure(self: PSteamNetworkingIdentity); cdecl;
  TIdentity_SetSteamID = procedure(self: PSteamNetworkingIdentity; steamID: UInt64); cdecl;

  TMessage_Release = procedure(self: PSteamNetworkingMessage_t); cdecl;

// --- Exported Variables (Function Pointers) ---
var
  GameNetworkingSockets_Init: TGameNetworkingSockets_Init;
  GameNetworkingSockets_Kill: TGameNetworkingSockets_Kill;

  SteamAPI_SteamNetworkingSockets_v009: TSteamAPI_SteamNetworkingSockets_v009;
  SteamAPI_ISteamNetworkingSockets_CreateListenSocketIP: TCreateListenSocketIP;
  SteamAPI_ISteamNetworkingSockets_ConnectByIPAddress: TConnectByIPAddress;
  SteamAPI_ISteamNetworkingSockets_AcceptConnection: TAcceptConnection;
  SteamAPI_ISteamNetworkingSockets_CloseConnection: TCloseConnection;
  SteamAPI_ISteamNetworkingSockets_SendMessageToConnection: TSendMessageToConnection;
  SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection: TReceiveMessagesOnConnection;
  SteamAPI_ISteamNetworkingSockets_GetConnectionInfo: TGetConnectionInfo;
  SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus: TGetConnectionRealTimeStatus;
  SteamAPI_ISteamNetworkingSockets_RunCallbacks: TRunCallbacks;
  SteamAPI_ISteamNetworkingSockets_CreatePollGroup: TCreatePollGroup;
  SteamAPI_ISteamNetworkingSockets_DestroyPollGroup: TDestroyPollGroup;
  SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup: TSetConnectionPollGroup;
  SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnPollGroup: TReceiveMessagesOnPollGroup;

  SteamAPI_SteamNetworkingUtils_v003: TSteamAPI_SteamNetworkingUtils_v003;
  SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess: TInitRelayNetworkAccess;
  SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus: TGetRelayNetworkStatus;
  SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32: TSetGlobalConfigValueInt32;
  SteamAPI_ISteamNetworkingUtils_GetLocalTimestamp: TGetLocalTimestamp;
  SteamAPI_ISteamNetworkingUtils_SetDebugOutputFunction: TSetDebugOutputFunction;

  SteamAPI_SteamNetworkingIPAddr_Clear: TIPAddr_Clear;
  SteamAPI_SteamNetworkingIPAddr_SetIPv4: TIPAddr_SetIPv4;
  SteamAPI_SteamNetworkingIPAddr_ToString: TIPAddr_ToString;

  SteamAPI_SteamNetworkingIdentity_Clear: TIdentity_Clear;
  SteamAPI_SteamNetworkingIdentity_SetSteamID: TIdentity_SetSteamID;

  SteamAPI_SteamNetworkingMessage_t_Release: TMessage_Release;

// Loads the DLL and binds all functions. Returns true on success.
function LoadGameNetworkingSocketsDLL: Boolean;

implementation

var
  hDLL: THandle = 0;

function LoadGameNetworkingSocketsDLL: Boolean;
  // Helper: Binds a procedure by name, automatically trying C++ name mangling fallbacks.
  procedure BindProc(AName: string; out APtr: Pointer);
  var
    AltName: string;
  begin
    APtr := GetProcAddress(hDLL, PChar(AName));
    if not Assigned(APtr) then
    begin
      AltName := AName + '@4'; // Fallback for MSVC stdcall decorator on pointers
      APtr := GetProcAddress(hDLL, PChar(AltName));
    end;
    if not Assigned(APtr) then
      OutputDebugString(PChar('GameNetworkingSockets: Function not found: ' + AName));
  end;

  // Helper: Specific binding for the main Init function due to heavy C++ mangling.
  procedure BindMainInit(out APtr: Pointer);
  begin
    APtr := GetProcAddress(hDLL, 'GameNetworkingSockets_Init');
    if not Assigned(APtr) then
      APtr := GetProcAddress(hDLL, '_Z35GameNetworkingSockets_InitPK22SteamNetworkingIPAddrPc');
  end;

begin
  Result := False;
  if hDLL <> 0 then Exit(True); // Already loaded

  hDLL := LoadLibrary('GameNetworkingSockets.dll');
  if hDLL = 0 then Exit;

  Result := True;

  BindMainInit(@GameNetworkingSockets_Init);
  BindProc('GameNetworkingSockets_Kill', @GameNetworkingSockets_Kill);

  BindProc('SteamAPI_SteamNetworkingSockets_v009', @SteamAPI_SteamNetworkingSockets_v009);
  BindProc('SteamAPI_ISteamNetworkingSockets_CreateListenSocketIP', @SteamAPI_ISteamNetworkingSockets_CreateListenSocketIP);
  BindProc('SteamAPI_ISteamNetworkingSockets_ConnectByIPAddress', @SteamAPI_ISteamNetworkingSockets_ConnectByIPAddress);
  BindProc('SteamAPI_ISteamNetworkingSockets_AcceptConnection', @SteamAPI_ISteamNetworkingSockets_AcceptConnection);
  BindProc('SteamAPI_ISteamNetworkingSockets_CloseConnection', @SteamAPI_ISteamNetworkingSockets_CloseConnection);
  BindProc('SteamAPI_ISteamNetworkingSockets_SendMessageToConnection', @SteamAPI_ISteamNetworkingSockets_SendMessageToConnection);
  BindProc('SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection', @SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection);
  BindProc('SteamAPI_ISteamNetworkingSockets_GetConnectionInfo', @SteamAPI_ISteamNetworkingSockets_GetConnectionInfo);
  BindProc('SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus', @SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus);
  BindProc('SteamAPI_ISteamNetworkingSockets_RunCallbacks', @SteamAPI_ISteamNetworkingSockets_RunCallbacks);
  BindProc('SteamAPI_ISteamNetworkingSockets_CreatePollGroup', @SteamAPI_ISteamNetworkingSockets_CreatePollGroup);
  BindProc('SteamAPI_ISteamNetworkingSockets_DestroyPollGroup', @SteamAPI_ISteamNetworkingSockets_DestroyPollGroup);
  BindProc('SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup', @SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup);
  BindProc('SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnPollGroup', @SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnPollGroup);

  BindProc('SteamAPI_SteamNetworkingUtils_v003', @SteamAPI_SteamNetworkingUtils_v003);
  BindProc('SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess', @SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess);
  BindProc('SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus', @SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus);
  BindProc('SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32', @SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32);
  BindProc('SteamAPI_ISteamNetworkingUtils_GetLocalTimestamp', @SteamAPI_ISteamNetworkingUtils_GetLocalTimestamp);
  BindProc('SteamAPI_ISteamNetworkingUtils_SetDebugOutputFunction', @SteamAPI_ISteamNetworkingUtils_SetDebugOutputFunction);

  BindProc('SteamAPI_SteamNetworkingIPAddr_Clear', @SteamAPI_SteamNetworkingIPAddr_Clear);
  BindProc('SteamAPI_SteamNetworkingIPAddr_SetIPv4', @SteamAPI_SteamNetworkingIPAddr_SetIPv4);
  BindProc('SteamAPI_SteamNetworkingIPAddr_ToString', @SteamAPI_SteamNetworkingIPAddr_ToString);

  BindProc('SteamAPI_SteamNetworkingIdentity_Clear', @SteamAPI_SteamNetworkingIdentity_Clear);
  BindProc('SteamAPI_SteamNetworkingIdentity_SetSteamID', @SteamAPI_SteamNetworkingIdentity_SetSteamID);

  BindProc('SteamAPI_SteamNetworkingMessage_t_Release', @SteamAPI_SteamNetworkingMessage_t_Release);
end;

end.
