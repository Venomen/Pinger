//
//  HTTPMonitor.swift
//  Pinger
//
//  Created by Dawid Deregowski on 19/09/2025.
//

import Foundation

// MARK: - HTTP Monitor
class HTTPMonitor {
    
    func checkHTTP(host: String, completion: @escaping (Bool, Int?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let (result, status) = self.runCheckOnceHTTP(host: host)
            DispatchQueue.main.async {
                completion(result, status)
            }
        }
    }
    
    private func runCheckOnceHTTP(host: String) -> (Bool, Int?) {
        // Determine URL
        let urlString: String
        if host.hasPrefix("http://") || host.hasPrefix("https://") {
            urlString = host
        } else {
            // Default to https, fallback to http
            urlString = "https://\(host)"
        }
        
        guard let url = URL(string: urlString) else {
            AppLogger.L("Invalid URL: \(urlString)")
            return (false, nil)
        }
        
        return checkHTTPUrl(url: url, redirectCount: 0)
    }

    private func checkHTTPUrl(url: URL, redirectCount: Int) -> (Bool, Int?) {
        if redirectCount > Config.maxRedirects {
            AppLogger.L("Too many redirects for \(url)")
            return (false, nil)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = Config.httpTimeout
        request.httpMethod = "HEAD" // Faster than GET
        request.setValue("Pinger/1.0", forHTTPHeaderField: "User-Agent")
        
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        var httpStatus: Int? = nil
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                AppLogger.L("HTTP error for \(url): \(error)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.L("Invalid HTTP response for \(url)")
                return
            }
            
            httpStatus = httpResponse.statusCode
            AppLogger.L("HTTP \(httpStatus!) for \(url)")
            
            switch httpResponse.statusCode {
            case 200...299:
                result = true
                
            case 301, 302, 303, 307, 308:
                if let location = httpResponse.value(forHTTPHeaderField: "Location"),
                   let redirectUrl = URL(string: location) {
                    let (redirectResult, _) = self.checkHTTPUrl(url: redirectUrl, redirectCount: redirectCount + 1)
                    result = redirectResult
                }
                
            default:
                result = false
            }
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + Config.httpTimeout + 1)
        
        return (result, httpStatus)
    }
    
    private func extractHostFromUrl(_ url: URL) -> String? {
        return url.host
    }
}