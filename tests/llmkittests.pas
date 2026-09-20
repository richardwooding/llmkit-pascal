{ Test runner: ./llmkittests --format=plain --all

  Everything runs offline; the provider tests talk to an in-process fake
  vendor bound to 127.0.0.1.
}
program llmkittests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, consoletestrunner,
  TestSupport, TestCore, TestRouting, TestWire, TestTools;

var
  App: TTestRunner;

begin
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'llmkit-pascal test suite';
    App.Run;
  finally
    App.Free;
  end;
end.
