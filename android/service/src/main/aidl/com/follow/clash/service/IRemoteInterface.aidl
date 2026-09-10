// IRemoteInterface.aidl
package com.follow.clash.service;

import com.follow.clash.service.ICallbackInterface;
import com.follow.clash.service.IEventInterface;
import com.follow.clash.service.IResultInterface;
import com.follow.clash.service.IVoidInterface;
import com.follow.clash.service.IOperationResultInterface;
import com.follow.clash.service.models.VpnOptions;
import com.follow.clash.service.models.NotificationParams;
import com.follow.clash.service.models.SessionSnapshot;

interface IRemoteInterface {
    void invokeAction(in String data, in ICallbackInterface callback);
    void quickSetup(in String initParamsString, in String setupParamsString, in IOperationResultInterface result);
    void updateNotificationParams(in NotificationParams params);
    void startService(in VpnOptions options, in long runTime, in IOperationResultInterface result);
    void stopService(in IOperationResultInterface result);
    void clearTaskRemovalStop();
    void setEventListener(in IEventInterface event);
    long getRunTime();
    SessionSnapshot getSessionSnapshot();
    void smartStop(in IResultInterface result);
    void smartResume(in IResultInterface result);
    void setSmartStopped(boolean value);
    boolean isSmartStopped();
    void updateSmartPauseConfig(boolean enabled, in List<String> trustedNetworks, boolean closeConnections);
    void reevaluateSmartPause(in IResultInterface result);
    void reconfigureSettings(in VpnOptions options, long expectedSessionId, in IOperationResultInterface result);
}
