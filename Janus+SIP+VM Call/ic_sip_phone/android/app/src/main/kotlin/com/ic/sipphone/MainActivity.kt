// MainActivity.kt: the SIP engine of IC SIP Phone (Linphone SDK), driven from Flutter.
//
// Works like MizuDroid: registers <name>@ic.local directly on FreeSWITCH's "phones"
// profile (UDP 5090) with password 1234, and sends/receives plain RTP. The phone
// supports PCMU, PCMA, GSM and Opus; FreeSWITCH offers only the codec of the user's
// group (A PCMU, B GSM, C PCMA), so that is the one used.
//
// Flutter talks to it over two channels:
//   MethodChannel "ic/sip"        register, unregister, call, accept, decline, hangup, mute, speaker
//   EventChannel  "ic/sip/events" {type: registration|call, state, message|peer|codec|reason}
package com.ic.sipphone

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.linphone.core.Account
import org.linphone.core.AudioDevice
import org.linphone.core.Call
import org.linphone.core.Core
import org.linphone.core.CoreListenerStub
import org.linphone.core.Factory
import org.linphone.core.MediaEncryption
import org.linphone.core.Reason
import org.linphone.core.RegistrationState

class MainActivity : FlutterActivity() {
    private lateinit var core: Core
    private var events: EventChannel.EventSink? = null

    private val listener = object : CoreListenerStub() {
        override fun onAccountRegistrationStateChanged(
            core: Core, account: Account, state: RegistrationState?, message: String
        ) {
            send(mapOf("type" to "registration", "state" to (state?.name ?: "None"), "message" to message))
        }

        override fun onCallStateChanged(core: Core, call: Call, state: Call.State?, message: String) {
            val s = when (state) {
                Call.State.IncomingReceived -> "incoming"
                Call.State.OutgoingInit, Call.State.OutgoingProgress -> "calling"
                Call.State.OutgoingRinging, Call.State.OutgoingEarlyMedia -> "ringing"
                Call.State.Connected, Call.State.StreamsRunning -> "active"
                Call.State.End, Call.State.Error -> "ended"
                else -> return
            }
            val pt = call.currentParams.usedAudioPayloadType
            val codec = if (pt != null) "${pt.mimeType}/${pt.clockRate}" else ""
            val ei = call.errorInfo
            val reason = if (ei.protocolCode != 0) "${ei.protocolCode} ${ei.phrase ?: ""}".trim() else message
            send(mapOf("type" to "call", "state" to s, "peer" to (call.remoteAddress.username ?: ""),
                       "codec" to codec, "reason" to reason))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val factory = Factory.instance()
        factory.setDebugMode(true, "ICSIP") // logs: adb logcat | grep ICSIP
        core = factory.createCore(null, null, this)
        core.isIpv6Enabled = false
        core.isKeepAliveEnabled = true      // keeps the UDP NAT mapping open, like MizuDroid
        core.maxCalls = 1                   // a second incoming call gets 486 Busy
        core.transports = factory.createTransports().apply { udpPort = -1; tcpPort = 0; tlsPort = 0 }
        val wanted = setOf("PCMU", "PCMA", "GSM", "OPUS", "TELEPHONE-EVENT")
        for (pt in core.audioPayloadTypes) pt.enable(pt.mimeType.uppercase() in wanted)
        core.addListener(listener)
        core.start()

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "ic/sip/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
        })
        MethodChannel(messenger, "ic/sip").setMethodCallHandler { req, result ->
            try {
                when (req.method) {
                    "register" -> register(
                        req.argument<String>("name")!!, req.argument<String>("server")!!,
                        req.argument<Int>("port")!!, req.argument<String>("domain")!!,
                        req.argument<String>("password")!!)
                    "unregister" -> unregister()
                    "call" -> dial(req.argument<String>("name")!!, req.argument<String>("domain")!!)
                    "accept" -> incoming()?.accept()
                    "decline" -> incoming()?.decline(Reason.Declined)
                    "hangup" -> core.terminateAllCalls()
                    "mute" -> core.isMicEnabled = !(req.argument<Boolean>("on") ?: false)
                    "speaker" -> speaker(req.argument<Boolean>("on") ?: false)
                    else -> { result.notImplemented(); return@setMethodCallHandler }
                }
                result.success(null)
            } catch (e: Exception) {
                result.error("SIP", e.message, null)
            }
        }
    }

    /** Register name@domain on FreeSWITCH (server:port over UDP). All SIP, calls too, goes there. */
    private fun register(name: String, server: String, port: Int, domain: String, password: String) {
        unregister()
        val factory = Factory.instance()
        val proxy = factory.createAddress("sip:$server:$port;transport=udp")
            ?: throw IllegalArgumentException("bad server address")
        val params = core.createAccountParams()
        params.identityAddress = factory.createAddress("sip:$name@$domain")
        params.serverAddress = proxy
        params.setRoutesAddresses(arrayOf(proxy)) // calls to x@ic.local go to FreeSWITCH, not to DNS
        params.isRegisterEnabled = true
        params.expires = 300
        core.addAuthInfo(factory.createAuthInfo(name, null, password, null, null, domain, null))
        val account = core.createAccount(params)
        core.addAccount(account)
        core.defaultAccount = account
    }

    /** Remove every account; Linphone sends the un-REGISTER for each. */
    private fun unregister() {
        for (a in core.accountList.toList()) core.removeAccount(a)
    }

    private fun dial(name: String, domain: String) {
        val addr = Factory.instance().createAddress("sip:$name@$domain")
            ?: throw IllegalArgumentException("bad name")
        val params = core.createCallParams(null) ?: throw IllegalStateException("no call params")
        params.mediaEncryption = MediaEncryption.None // plain RTP, like MizuDroid
        core.inviteAddressWithParams(addr, params)
    }

    private fun incoming(): Call? = core.calls.firstOrNull { it.state == Call.State.IncomingReceived }

    private fun speaker(on: Boolean) {
        val type = if (on) AudioDevice.Type.Speaker else AudioDevice.Type.Earpiece
        val device = core.audioDevices.firstOrNull { it.type == type } ?: return
        core.currentCall?.outputAudioDevice = device
    }

    private fun send(event: Map<String, Any>) {
        events?.success(event)
    }

    override fun onDestroy() {
        if (::core.isInitialized) {
            core.removeListener(listener)
            core.stop()
        }
        super.onDestroy()
    }
}
