unit Yutani.AI.Client;

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.Net.HttpClient,
  System.Net.URLClient;

type
  /// <summary>Event fired when an action tag like 'nod' or 'shake' was detected.</summary>
  TYutaniActionTagEvent = procedure(Sender: TObject; const ATag: string) of object;

  /// <summary>Event fired with the spoken text (tag stripped).</summary>
  TYutaniResponseEvent = procedure(Sender: TObject; const ASpokenText: string) of object;

  /// <summary>Event fired on error with a human-readable message.</summary>
  TYutaniErrorEvent = procedure(Sender: TObject; const AErrorMsg: string) of object;

  /// <summary>Simple notification event.</summary>
  TYutaniNotifyEvent = procedure(Sender: TObject) of object;

  /// <summary>
  ///   Slim, framework-independent async client for any OpenAI-compatible
  ///   chat/completions REST endpoint (Ollama, LM Studio, Groq, OpenRouter, OpenAI).
  /// </summary>
  TYutaniAIClient = class(TComponent)
  private
    FBaseURL: string;
    FApiKey: string;
    FModel: string;
    FSystemPrompt: string;
    FMaxHistoryMessages: Integer;
    FHistory: TJSONArray;
    FOnThinking: TYutaniNotifyEvent;
    FOnActionTag: TYutaniActionTagEvent;
    FOnResponse: TYutaniResponseEvent;
    FOnError: TYutaniErrorEvent;
    FLock: TObject;
    function BuildRequestBody(const AUserText: string): string;
    procedure AddToHistory(const ARole, AContent: string);
    procedure TrimHistory;
    procedure ParseResponse(const AJSONText: string);
    procedure FireThinking;
    procedure FireActionTag(const ATag: string);
    procedure FireResponse(const ASpokenText: string);
    procedure FireError(const AErrorMsg: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    /// <summary>Sends the user text asynchronously. Returns immediately.</summary>
    procedure AskAsync(const AUserText: string);

    /// <summary>Clears the conversation history.</summary>
    procedure ClearHistory;

    property BaseURL: string read FBaseURL write FBaseURL;
    property ApiKey: string read FApiKey write FApiKey;
    property Model: string read FModel write FModel;
    property SystemPrompt: string read FSystemPrompt write FSystemPrompt;
    property MaxHistoryMessages: Integer read FMaxHistoryMessages write FMaxHistoryMessages;

    property OnThinking: TYutaniNotifyEvent read FOnThinking write FOnThinking;
    property OnActionTag: TYutaniActionTagEvent read FOnActionTag write FOnActionTag;
    property OnResponse: TYutaniResponseEvent read FOnResponse write FOnResponse;
    property OnError: TYutaniErrorEvent read FOnError write FOnError;
  end;

implementation

const
  DEFAULT_BASE_URL = 'http://localhost:11434/v1/chat/completions';
  DEFAULT_MODEL = 'llama3.2';
  DEFAULT_SYSTEM_PROMPT = 'You are C.H.A.O.S., a dry, witty AI living inside a 3D particle hologram. ' + 'Start EVERY reply with exactly one gesture tag from [neutral], [nod], ' + '[shake], [tilt], [think], [alert], followed by a concise spoken answer ' + '(max 2 sentences, no markdown or emojis).';
  ALLOWED_TAGS: array[0..5] of string = ('neutral', 'nod', 'shake', 'tilt', 'think', 'alert');

{ ---------------------------------------------------------------------------- }
{ Background worker                                                             }
{ ---------------------------------------------------------------------------- }

type
  TYutaniAskThread = class(TThread)
  private
    FClient: TYutaniAIClient;
    FUserText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TYutaniAIClient; const AUserText: string);
  end;

constructor TYutaniAskThread.Create(AClient: TYutaniAIClient; const AUserText: string);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FClient := AClient;
  FUserText := AUserText;
end;

procedure TYutaniAskThread.Execute;
var
  HttpClient: THTTPClient;
  RequestBody: string;
  Response: IHTTPResponse;
  Headers: TNetHeaders;
  PostData: TStringStream;
begin
  FClient.FireThinking;
  RequestBody := FClient.BuildRequestBody(FUserText);

  HttpClient := THTTPClient.Create;
  PostData := TStringStream.Create(RequestBody, TEncoding.UTF8);
  try
    HttpClient.ConnectionTimeout := 15000;
    HttpClient.ResponseTimeout := 120000;
    HttpClient.ContentType := 'application/json';

    SetLength(Headers, 0);
    if FClient.ApiKey <> '' then
    begin
      SetLength(Headers, 1);
      Headers[0].Name := 'Authorization';
      Headers[0].Value := 'Bearer ' + FClient.ApiKey;
    end;

    try
      Response := HttpClient.Post(FClient.BaseURL, PostData, nil, Headers);
      if (Response.StatusCode >= 200) and (Response.StatusCode < 300) then
        FClient.ParseResponse(Response.ContentAsString(TEncoding.UTF8))
      else
        FClient.FireError(Format('HTTP %d: %s', [Response.StatusCode, Response.StatusText]));
    except
      on E: Exception do
        FClient.FireError(E.Message);
    end;
  finally
    PostData.Free;
    HttpClient.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TYutaniAIClient                                                              }
{ ---------------------------------------------------------------------------- }

constructor TYutaniAIClient.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TObject.Create;
  FHistory := TJSONArray.Create;
  FBaseURL := DEFAULT_BASE_URL;
  FApiKey := '';
  FModel := DEFAULT_MODEL;
  FSystemPrompt := DEFAULT_SYSTEM_PROMPT;
  FMaxHistoryMessages := 10;
end;

destructor TYutaniAIClient.Destroy;
begin
  FHistory.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TYutaniAIClient.ClearHistory;
begin
  TMonitor.Enter(FLock);
  try
    FHistory.Free;
    FHistory := TJSONArray.Create;
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TYutaniAIClient.AddToHistory(const ARole, AContent: string);
var
  Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  Obj.AddPair('role', ARole);
  Obj.AddPair('content', AContent);
  FHistory.AddElement(Obj);
end;

procedure TYutaniAIClient.TrimHistory;
var
  Limit, I: Integer;
  Temp: TJSONArray;
begin
  Limit := FMaxHistoryMessages * 2;
  if Limit < 2 then
    Limit := 2;

  while FHistory.Count > Limit do
  begin
    Temp := TJSONArray.Create;
    try
      for I := 1 to FHistory.Count - 1 do
        Temp.AddElement(FHistory.Items[I].Clone as TJSONValue);
    finally
      FHistory.Free;
      FHistory := Temp;
    end;
  end;
end;

function TYutaniAIClient.BuildRequestBody(const AUserText: string): string;
var
  Root, Msg: TJSONObject;
  Messages: TJSONArray;
  I: Integer;
begin
  TMonitor.Enter(FLock);
  try
    AddToHistory('user', AUserText);
    TrimHistory;

    Messages := TJSONArray.Create;

    Msg := TJSONObject.Create;
    Msg.AddPair('role', 'system');
    Msg.AddPair('content', FSystemPrompt);
    Messages.AddElement(Msg);

    for I := 0 to FHistory.Count - 1 do
      Messages.AddElement(FHistory.Items[I].Clone as TJSONValue);

    Root := TJSONObject.Create;
    try
      Root.AddPair('model', FModel);
      Root.AddPair('messages', Messages);
      Root.AddPair('stream', TJSONBool.Create(False));
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TYutaniAIClient.ParseResponse(const AJSONText: string);
var
  Root, Choice, Message: TJSONObject;
  Choices: TJSONArray;
  Content, Tag, Spoken: string;
  P, I: Integer;
  LowerContent: string;
  Matched: Boolean;
begin
  try
    Root := TJSONObject.ParseJSONValue(AJSONText) as TJSONObject;
  except
    FireError('Invalid JSON response.');
    Exit;
  end;

  if Root = nil then
  begin
    FireError('Empty JSON response.');
    Exit;
  end;

  try
    if not Root.TryGetValue<TJSONArray>('choices', Choices) or (Choices.Count = 0) then
    begin
      FireError('No choices in response.');
      Exit;
    end;

    Choice := Choices.Items[0] as TJSONObject;
    if not Choice.TryGetValue<TJSONObject>('message', Message) then
    begin
      FireError('No message in choice.');
      Exit;
    end;

    if not Message.TryGetValue<string>('content', Content) then
    begin
      FireError('No content in message.');
      Exit;
    end;

    Content := Content.Trim;
    Spoken := Content;
    Tag := '';

    if (Length(Content) > 2) and (Content[1] = '[') then
    begin
      P := Pos(']', Content);
      if P > 1 then
      begin
        LowerContent := LowerCase(Copy(Content, 2, P - 2));
        Matched := False;
        for I := Low(ALLOWED_TAGS) to High(ALLOWED_TAGS) do
          if LowerContent = ALLOWED_TAGS[I] then
          begin
            Matched := True;
            Break;
          end;
        if Matched then
        begin
          Tag := LowerContent;
          Spoken := Copy(Content, P + 1, MaxInt).Trim;
        end;
      end;
    end;

    TMonitor.Enter(FLock);
    try
      AddToHistory('assistant', Content);
      TrimHistory;
    finally
      TMonitor.Exit(FLock);
    end;

    if Tag <> '' then
      FireActionTag(Tag);

    FireResponse(Spoken);
  finally
    Root.Free;
  end;
end;

{ Thread-safe event firing ---------------------------------------------------- }

procedure TYutaniAIClient.FireThinking;
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnThinking) then
        FOnThinking(Self);
    end);
end;

procedure TYutaniAIClient.FireActionTag(const ATag: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnActionTag) then
        FOnActionTag(Self, ATag);
    end);
end;

procedure TYutaniAIClient.FireResponse(const ASpokenText: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnResponse) then
        FOnResponse(Self, ASpokenText);
    end);
end;

procedure TYutaniAIClient.FireError(const AErrorMsg: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if Assigned(FOnError) then
        FOnError(Self, AErrorMsg);
    end);
end;

procedure TYutaniAIClient.AskAsync(const AUserText: string);
begin
  TYutaniAskThread.Create(Self, AUserText).Start;
end;

end.

