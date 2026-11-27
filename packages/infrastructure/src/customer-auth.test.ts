import { afterEach, describe, expect, it } from "vitest";
import {
  createSmsProvider,
  MockSmsProvider,
} from "./customer-auth";

const originalNodeEnv = process.env.NODE_ENV;
const originalProvider = process.env.FCO_SMS_PROVIDER;
const originalE2eMode = process.env.FCO_E2E_MODE;

afterEach(() => {
  if (originalNodeEnv === undefined) {
    delete process.env.NODE_ENV;
  } else {
    process.env.NODE_ENV = originalNodeEnv;
  }
  if (originalProvider === undefined) {
    delete process.env.FCO_SMS_PROVIDER;
  } else {
    process.env.FCO_SMS_PROVIDER = originalProvider;
  }
  if (originalE2eMode === undefined) {
    delete process.env.FCO_E2E_MODE;
  } else {
    process.env.FCO_E2E_MODE = originalE2eMode;
  }
});

describe("customer SMS provider selection", () => {
  it("uses the mock spool provider for local and test environments", () => {
    process.env.NODE_ENV = "test";
    process.env.FCO_SMS_PROVIDER = "mock";
    delete process.env.FCO_E2E_MODE;

    expect(createSmsProvider()).toBeInstanceOf(MockSmsProvider);
  });

  it("does not allow the mock provider in production outside E2E", () => {
    process.env.NODE_ENV = "production";
    process.env.FCO_SMS_PROVIDER = "mock";
    delete process.env.FCO_E2E_MODE;

    expect(() => createSmsProvider()).toThrow(
      "No production SMS provider is configured; customer OTP delivery is unavailable.",
    );
  });
});
