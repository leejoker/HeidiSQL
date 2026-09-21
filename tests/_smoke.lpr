program _smoke;
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX} cthreads, cwstring, {$ENDIF}
  SysUtils, redisclient;
var
  c: TRedisClient;
  v: TRedisValue;
  mode: string;
begin
  mode := ParamStr(1);
  if mode = '' then mode := 'r2';
  c := TRedisClient.Create;
  try
    if mode = 'r2' then
      c.Connect('127.0.0.1', 6399, '', '', 0)
    else
      c.Connect('127.0.0.1', 6400, 'alice', 'secret', 1);
    writeln('connected, protocol=', c.Protocol);
    v := c.Execute(['SET', 'k', 'v']);
    writeln('SET -> kind=', Ord(v.Kind), ' str=', v.Str);
    v.Free;
    v := c.Execute(['GET', 'k']);
    try
      writeln('GET k -> kind=', Ord(v.Kind), ' str=', v.Str);
    finally
      v.Free;
    end;
    c.Disconnect;
    writeln(mode, ' smoke OK');
  finally
    c.Free;
  end;
end.
