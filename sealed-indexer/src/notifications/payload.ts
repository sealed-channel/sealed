/**
 * Notification payload builder for FCM/APNs.
 * Enforces D4 payload contract: content-free notifications with whitelisted metadata only.
 */

export interface NotificationData {
  message_id: string;
  conversation_wallet: string;
  account_pubkey: string;
}

export interface FcmLikeMessage {
  message: {
    token: string;
    notification: {
      title: string;
      body: string;
    };
    data: Record<string, string>;
  };
}

/**
 * Builds a canonical FCM HTTP v1 notification payload.
 * - Hard-coded title/body for content-free notifications
 * - Uses allowlist for data keys to prevent leaking note content
 * - APNs routed through FCM - no separate APNs payload shape
 */
export function buildNotificationPayload(
  platform: 'ios' | 'android',
  token: string,
  data: NotificationData
): FcmLikeMessage {
  // Allowlist approach - only copy whitelisted keys to prevent note leakage
  const allowedData: Record<string, string> = {
    message_id: data.message_id,
    conversation_wallet: data.conversation_wallet,
    account_pubkey: data.account_pubkey,
  };

  return {
    message: {
      token,
      notification: {
        title: 'New Encrypted Message',
        body: 'You have a new message.',
      },
      data: allowedData,
    },
  };
}