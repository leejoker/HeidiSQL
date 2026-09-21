unit dbstructures.redis;

{$mode delphi}{$H+}

interface

uses
  dbstructures;

type
  { TRedisProvider — Redis 不使用 SQL provider。此类存在仅是为了让
    TDBConnection.Connect 的 case NetTypeGroup 能为 ngRedis 创建一个 provider
    实例而不落入 else raise。GetSql 对所有 id 抛 EDbError。 }
  TRedisProvider = class(TSqlProvider)
  public
    function GetSql(AId: TQueryId): string; overload; override;
  end;

implementation

{$I const.inc}

function TRedisProvider.GetSql(AId: TQueryId): string;
begin
  // Redis 不使用 SQL。返回空串而非抛异常，让调用方通过 IsEmpty 检查安全跳过。
  Result := '';
end;

end.
