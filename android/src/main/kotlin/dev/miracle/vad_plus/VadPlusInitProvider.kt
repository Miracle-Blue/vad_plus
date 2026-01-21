package dev.miracle.vad_plus

import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.util.Log

/**
 * VadPlusInitProvider - Automatically initializes the application context
 * 
 * This ContentProvider is used to automatically capture the application context
 * when the app starts, without requiring any manual initialization from the user.
 * 
 * This pattern is used by many popular libraries (Firebase, WorkManager, etc.)
 * 
 * IMPORTANT: This also loads the native library via System.loadLibrary() which
 * triggers JNI_OnLoad and caches the JavaVM pointer. This MUST happen before
 * Dart FFI tries to use the library, otherwise JNI calls will fail.
 */
class VadPlusInitProvider : ContentProvider() {
    
    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext
        if (appContext != null) {
            VadPlusHandleManager.applicationContext = appContext
            
            // Load native library via JVM to trigger JNI_OnLoad
            // This caches the JavaVM pointer needed for JNI operations
            try {
                System.loadLibrary("vad_plus")
                Log.d(TAG, "VadPlus native library loaded successfully")
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "Failed to load native library: ${e.message}")
            }
            
            Log.d(TAG, "VadPlus initialized with application context")
        } else {
            Log.w(TAG, "Failed to get application context during initialization")
        }
        return true
    }
    
    override fun query(uri: Uri, projection: Array<String>?, selection: String?, 
                      selectionArgs: Array<String>?, sortOrder: String?): Cursor? = null
    
    override fun getType(uri: Uri): String? = null
    
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = 0
    
    override fun update(uri: Uri, values: ContentValues?, selection: String?, 
                       selectionArgs: Array<String>?): Int = 0
    
    companion object {
        private const val TAG = "VadPlusInitProvider"
    }
}
